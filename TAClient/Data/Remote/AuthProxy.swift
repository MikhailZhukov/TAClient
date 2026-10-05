import Foundation
import Network
import OSLog

/// Shutdown flag plus the set of `NWConnection`s a listener has accepted.
///
/// `NWListener.cancel()` does not terminate connections that were already
/// accepted, and `AuthProxy`'s per-request handler streams an upstream body
/// with no timeout, so a proxy that is stopped while serving a client would
/// otherwise keep streaming (and keep holding the user's token) for as long as
/// the peer keeps the socket open. `shutdown()` flips the flag — which makes
/// `newConnectionHandler` refuse further work — and cancels everything in
/// flight, which in turn unwinds the streaming loop through its
/// `contentProcessed` failure.
///
/// The tracker is kept out of the actor's isolation domain because
/// `newConnectionHandler` and the connection's `receive` completion run on
/// arbitrary Network.framework queues; every access goes through the lock.
///
/// Isolation: `nonisolated final class … : @unchecked Sendable` with plain stored
/// properties — the repo convention for a lock-guarded, concurrency-neutral class,
/// identical to `CacheStore`. Required because `newConnectionHandler`, the
/// connection's `receive` completion and the terminal-state handler below all run on
/// arbitrary Network.framework queues and must reach this type's state without a
/// MainActor hop.
///
/// What does NOT work, both tried and both rejected:
/// - plain `final class` + `nonisolated` on methods only: de-isolating a method does
///   not de-isolate the properties it touches, so every access warns
///   "main actor-isolated property … can not be mutated from a nonisolated context";
/// - `nonisolated` on a mutable stored property: "'nonisolated' cannot be applied to
///   mutable stored properties".
///
/// The class-level form is the only one that covers mutable storage, and it is what
/// the existing lock-guarded types in this codebase use.
nonisolated final class AcceptedConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// Read and written only under `lock`. A plain stored property: the class-level
    /// `nonisolated` already makes it reachable cross-thread, so no
    /// `nonisolated(unsafe)` is needed, and none should be added — it would opt this
    /// flag out of checking that the lock is what actually protects it.
    private var shutdownFlag = false

    /// Whether the tracker refuses new connections. Lock-guarded read; exposed as a
    /// method-shaped accessor so the call sites cannot bypass the lock the way a
    /// bare property read would allow.
    var isShutdown: Bool {
        lock.withLock { shutdownFlag }
    }

    init(isShutdown: Bool = false) {
        self.shutdownFlag = isShutdown
    }

    /// Track a newly accepted connection and arm its terminal-state handler.
    ///
    /// The handler is installed here rather than at construction so the
    /// tracker→connection→handler cycle only exists while the tracker considers
    /// the connection live: `cancelAndRelease` nils both the map entry and the
    /// handler, which breaks the cycle and lets the connection go.
    ///
    /// Returns `false` when the tracker is already shut down — the caller must
    /// refuse the connection in that case, because it was deliberately not
    /// tracked and nothing else will cancel it.
    func install(_ connection: NWConnection) -> Bool {
        let tracked = lock.withLock { () -> Bool in
            guard !shutdownFlag else { return false }
            connections[ObjectIdentifier(connection)] = connection
            return true
        }
        if tracked {
            // `[weak self]` rather than a strong capture on purpose: the handler
            // is retained by the NWConnection, and the connection is retained by
            // this tracker's map. A strong `self` here would make the cycle
            // tracker -> connection -> handler -> tracker, and the only thing that
            // breaks it (`cancelAndRelease`) would then be reachable only through
            // the very cycle it has to dissolve. Weak also makes the intended
            // lifetime obvious: once the proxy drops the tracker, tracked sockets
            // stop being reported to it.
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .cancelled, .failed:
                    self?.cancelAndRelease(connection)
                default:
                    break
                }
            }
        }
        return tracked
    }

    func release(_ connection: NWConnection) {
        lock.withLock { connections[ObjectIdentifier(connection)] = nil }
    }

    /// Refuse future connections and cancel the ones already accepted.
    ///
    /// Does NOT clear the map: `NWConnection.cancel()` is asynchronous, and a
    /// connection stays tracked until `cancelAndRelease` confirms it is
    /// terminal. That keeps `shutdown()` idempotent — a second call (for example
    /// the tracker's own `.stateUpdateHandler` firing `.cancelled` while the
    /// first pass is still unwinding) re-cancels the same set instead of
    /// silently doing nothing, which matters because `AuthProxy.stop()` clears
    /// its own reference to the tracker immediately after the first call.
    func shutdown() {
        let pending = lock.withLock { () -> [NWConnection] in
            shutdownFlag = true
            return Array(connections.values)
        }
        for connection in pending { connection.cancel() }
    }

    /// Drop a connection the framework reports as terminal, so a tracker that
    /// outlives its proxy (Network.framework keeps the connection alive until
    /// the close completes) does not pin dead peers indefinitely.
    func cancelAndRelease(_ connection: NWConnection) {
        let known = lock.withLock { () -> Bool in
            guard connections[ObjectIdentifier(connection)] != nil else { return false }
            connections[ObjectIdentifier(connection)] = nil
            return true
        }
        if known { connection.cancel() }
    }

    var count: Int {
        lock.withLock { connections.count }
    }
}

/// Local HTTP proxy that adds the `Authorization: Token` header to requests
/// for server media. Used wherever the player cannot attach the header itself:
/// VLCKit (no custom headers), AVPlayer's direct-streaming fallback, and
/// AirPlay (the receiver fetches the URL on its own, never sees request
/// headers, and TA accepts the token only as a header).
///
/// The listener accepts local-network peers so an AirPlay receiver can reach
/// it. Every proxy URL starts with a random per-instance path secret, and
/// requests without it are refused, so other devices on the network cannot
/// use the proxy to reach the server with the user's token.
actor AuthProxy {
    private static let logger = Logger(subsystem: "ru.mzhukov.TAClient", category: "AuthProxy")
    private var listener: NWListener?
    private var port: UInt16 = 0
    private let token: String
    private let serverBaseURL: URL
    private let pathSecret = UUID().uuidString
    /// "The published listener was torn down." `stop()` sets it so a late `.failed`
    /// callback from the listener being cancelled cannot resurrect the proxy through
    /// `restartListener()` — `NWListener.cancel()` is asynchronous, so that callback
    /// really can land after `stop()` has already returned.
    ///
    /// Narrow on purpose, and NOT read by `stop()`: every `start()` clears it to open
    /// a new epoch. Using a boolean as `stop()`'s idempotency guard was the leak — the
    /// guard returned BEFORE the teardown assignments, so a second `stop()`, or one
    /// landing during a bind on a proxy already stopped once, skipped `port = 0` /
    /// `acceptedConnections = nil` and left a live socket nobody owns. The publish
    /// decision and idempotency live in `stoppedGeneration`, and `restartListener()`
    /// is gated on `listener != nil`, which cannot go stale.
    private var listenerWasTornDown = false
    /// Bumped by `start()` and captured by it before the first suspension: identifies
    /// the bind generation whose socket `stop()` would be tearing down.
    private var startEpoch = 0
    /// The `startEpoch` of the generation `stop()` last tore down, or `-1` when
    /// nothing has ever been stopped.
    ///
    /// One field carries both facts `stop()` must communicate across the bind's
    /// suspension point:
    /// - **that it ran** — stamped on every call, including the no-op second one, so
    ///   "the value is no longer `-1`/no longer mine" is exactly "a stop targeted the
    ///   socket I am producing";
    /// - **that nothing is live** — `start()` resets it to `-1` only when it actually
    ///   publishes, so a `stop()` landing in the gap between the bind poll and the
    ///   publish still reads as a change rather than being silently accepted.
    ///
    /// A boolean cannot express either fact. The stop flag reads identically for
    /// "stopped before this `start()` began" (must NOT veto a brand-new bind — that
    /// made a never-started proxy un-startable for life) and "stopped during this
    /// bind" (must unwind the new listener, or it stays bound with the token inside
    /// it and nobody will ever cancel it).
    private var stoppedGeneration = -1
    /// Shutdown flag plus the set of connections accepted by the current
    /// listener. `stop()` flips it and cancels everything still in flight, so
    /// no per-request streaming task survives the proxy that authorised it.
    /// Peers accepted by the current listener, so `stop()` can cancel them
    /// explicitly — `NWListener.cancel()` does not terminate already-accepted
    /// connections, which is the leak this branch exists to close.
    ///
    /// `internal`, not `private`, solely so `AuthProxyTestSupport.swift` (app target)
    /// can assert `stop()` tears the tracker down. `@testable import` from the test
    /// target would not reach `private`. Nothing outside those two files reads it.
    var acceptedConnections: AcceptedConnections?

    var localPort: UInt16 { port }

    init(token: String, serverBaseURL: URL) {
        self.token = token
        self.serverBaseURL = serverBaseURL
    }

    func start() async throws {
        // Open a new epoch before the first suspension: bump the epoch `stop()`
        // stamps against, clear the resurrection guard, and clear any stamp a
        // previous `stop()` left. A `stop()` that ran before this call (including on
        // a never-started instance) must not veto a brand-new bind, and a `stop()`
        // that lands during the poll must be detectable as a CHANGE of
        // `stoppedGeneration` rather than inferred from a flag that may predate us.
        startEpoch += 1
        listenerWasTornDown = false
        stoppedGeneration = -1
        let params = NWParameters.tcp
        #if !targetEnvironment(simulator)
        // The simulator's host network stack rejects even 127.0.0.1 peers under
        // acceptLocalOnly, so the flag only applies on devices.
        params.acceptLocalOnly = true
        #endif
        let listener = try NWListener(using: params, on: .any)

        // Always born UNSHUT down. The previous behaviour — inherit the stop flag — was
        // how "stopped before ever starting" poisoned a fresh tracker: a proxy stopped
        // once would refuse every connection for the rest of its life, and there is no
        // path that clears it. A tracker that outlives its bind is guarded instead by
        // the publish guard below, which unwinds the tracker on every failure path, so
        // nothing unrefusable can escape.
        let accepted = AcceptedConnections(isShutdown: false)
        self.acceptedConnections = accepted

        listener.newConnectionHandler = { [weak self, accepted] connection in
            guard let self, !accepted.isShutdown else {
                connection.cancel()
                return
            }
            guard accepted.install(connection) else {
                connection.cancel()
                return
            }
            connection.start(queue: .global(qos: .userInitiated))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                guard let data, error == nil else {
                    accepted.cancelAndRelease(connection)
                    return
                }
                Task { [weak self, accepted] in
                    guard let self, !accepted.isShutdown else {
                        accepted.cancelAndRelease(connection)
                        return
                    }
                    await self.processHTTPRequest(data, connection: connection)
                    accepted.release(connection)
                }
            }
        }

        let box = SendableBox<UInt16>(0)
        // Install before `start()`, then poll for `.ready` instead of parking a
        // `CheckedContinuation` on it. The continuation form had no way to be
        // handed back: a caller cancelled (or a timeout) while `start()` was
        // suspended left a continuation that nothing could resume, and the state
        // handler captured the continuation closure — which retains the listener —
        // installed on that listener forever.
        //
        // Inlined rather than held in a typed local: the handler's parameter type is
        // spelled differently depending on SDK/module-visibility settings
        // (`NWListener.State` with `MemberImportVisibility` on), so naming it is a
        // portability trap for no benefit.
        listener.stateUpdateHandler = { [box] state in
            switch state {
            case .ready:
                box.set(listener.port?.rawValue ?? 0)
            case .failed(let error):
                Self.logger.error("Listener failed while starting: \(error.localizedDescription)")
            default:
                break
            }
        }
        listener.start(queue: .global(qos: .userInitiated))

        let assignedPort: UInt16 = await withTaskCancellationHandler {
            var port: UInt16 = box.current
            while port == 0 && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                port = box.current
            }
            return port
        } onCancel: {
            // Nothing may keep the socket bound past a cancelled start.
            listener.stateUpdateHandler = nil
            listener.cancel()
        }

        guard !Task.isCancelled, assignedPort > 0 else {
            listener.stateUpdateHandler = nil
            accepted.shutdown()
            // Same orphan this branch fixed for the stopped-during-start path:
            // `accepted` was installed into the property before the poll, so every
            // throw out of here must release it or it stays reachable with its
            // shutdown flag set and no live listener behind it.
            if acceptedConnections === accepted { acceptedConnections = nil }
            listener.cancel()
            throw AppError.unknown(message: "AuthProxy failed to bind")
        }
        // Publish only if no `stop()` targeted this generation. `stop()` stamps
        // `stoppedGeneration = startEpoch` unconditionally — before its own
        // idempotency guard, so the no-op second call stamps too — and `start()`
        // clears the stamp when it opens the epoch. Any non-`-1` value therefore
        // means a `stop()` ran against the generation this bind is producing:
        // - one that landed *during* the poll cancelled a socket nobody else can
        //   find, because it was never published — handing it back leaks a bound
        //   listener with the token inside it;
        // - one that landed in the actor's queue while this body was still running
        //   (its `startEpoch` read is the epoch being produced), which is exactly
        //   the "stop raced the bind" case.
        guard stoppedGeneration == -1 else {
            accepted.shutdown()
            if acceptedConnections === accepted { acceptedConnections = nil }
            listener.stateUpdateHandler = nil
            listener.cancel()
            throw AppError.unknown(message: "AuthProxy stopped while starting")
        }

        // The bind succeeded and this generation owns the socket. The
        // stopped-vs-stopping distinction the guard above needed is carried entirely
        // by `stoppedGeneration`, which is cleared below so the socket reads as live.

        // Monitor listener state after start.
        //
        // This handler is the reason `AuthProxy` used to need a `deinit`: the
        // closure is retained by the `NWListener`, and `NWListener.cancel()` is
        // asynchronous — the framework keeps the listener (and therefore the
        // handler, and therefore `self` through the capture list) alive until
        // the socket is actually closed. Clearing it on every terminal state
        // releases that edge explicitly instead of relying on ARC to do it
        // after the fact.
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                Self.logger.error("Listener failed: \(error.localizedDescription)")
                // Release the listener reference held by this closure before
                // hopping to the actor; `restartListener` installs a fresh one.
                listener.stateUpdateHandler = nil
                Task { await self?.restartListener() }
            case .cancelled:
                Self.logger.info("Listener cancelled")
                listener.stateUpdateHandler = nil
            default:
                break
            }
        }

        self.listener = listener
        self.port = assignedPort
        // Live from now on: a `stop()` must find something to tear down.
        stoppedGeneration = -1
    }

    /// Rebind after a transport failure. A failed listener is already dead,
    /// so there is nothing to cancel here — cancelling it used to route
    /// through the same path as `stop()` and left the old listener's async
    /// `.cancelled` callback racing the new one.
    func restartListener() {
        // Rebind is allowed whenever a listener is actually live. The old gate read
        // the stop flag, which a no-op `stop()` (or one that landed before any bind)
        // left set with nothing live behind it — permanently vetoing a legitimate
        // rebind. `listener != nil` is the honest precondition: `stop()` nils the
        // listener in the same actor hop that tears it down, and a bind that lost the
        // publish race never set one.
        guard listener != nil else { return }
        Self.logger.warning("Attempting restart...")
        // The old listener's connections belong to a socket that is gone; drop
        // them and let `start()` install a fresh tracker.
        acceptedConnections?.shutdown()
        acceptedConnections = nil
        listener = nil
        port = 0
        Task {
            try? await self.start()
        }
    }

    func stop() {
        // Stamped FIRST and unconditionally, before the teardown body: a `start()`
        // suspended in its bind poll (or between the poll and its publish) must see
        // that this generation was stopped even when this call is the second/no-op
        // one for the live socket. Gating the teardown on a boolean was the bug: that
        // guard returned early on a repeat call and on a proxy stopped before it ever
        // started, and in both cases the in-flight bind went on to publish a listener
        // plus tracker that nobody would ever release.
        stoppedGeneration = startEpoch
        // Idempotency: a listener that is already gone has nothing left to tear down.
        // `listener == nil` means either "never bound" or "the bind is still in
        // flight" — in the latter case the stamp above is what makes the bind task
        // unwind its own socket, so this stays safe without a second teardown path.
        guard listener != nil else { return }
        listenerWasTornDown = true
        // Cancel in-flight request handlers before the listener. Each handler
        // streams an upstream body into an `NWConnection` with
        // `timeoutIntervalForRequest = 0`, so nothing else ends it: without this
        // the task, its `StreamingSession`, its upstream URLSession and its
        // 256 KB send buffer survive `stop()`, and on the AirPlay path a peer
        // that simply never reads keeps them alive indefinitely.
        acceptedConnections?.shutdown()
        acceptedConnections = nil
        // `cancel()` is asynchronous, but the state handler clears itself on
        // `.cancelled`/`.failed`, so the listener stops holding `self` through
        // the capture list without waiting for the socket to close. The proxy
        // needs no `deinit` for the listener any more — and must not grow one,
        // because dealloc used to be reachable only while Network.framework
        // still held the listener, which is precisely the window in which the
        // token inside it outlived `stop()`.
        listener?.cancel()
        listener = nil
        port = 0
    }

    /// Loopback URL for `originalURL`, for players running in this app.
    func proxyURL(for originalURL: URL) -> URL? {
        proxyURL(for: originalURL, host: "127.0.0.1")
    }

    /// Local-network URL for `originalURL`, for an AirPlay receiver that
    /// fetches the media itself. `nil` when the device has no local-network
    /// IPv4 address (AirPlay needs Wi-Fi or Ethernet anyway).
    func networkURL(for originalURL: URL) -> URL? {
        guard let host = Self.localNetworkIPv4Address() else { return nil }
        return proxyURL(for: originalURL, host: host)
    }

    private func proxyURL(for originalURL: URL, host: String) -> URL? {
        guard port > 0,
              let original = URLComponents(url: originalURL, resolvingAgainstBaseURL: false) else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        components.percentEncodedPath = "/" + pathSecret + original.percentEncodedPath
        components.percentEncodedQuery = original.percentEncodedQuery
        return components.url
    }

    /// Server path for a proxied request target, or `nil` when the target
    /// lacks the path secret. Only origin-form targets (`/secret/...`) are
    /// accepted, so the proxy never forwards to a host other than the server.
    nonisolated static func upstreamPath(forRequestTarget target: String, secret: String) -> String? {
        let prefix = "/" + secret + "/"
        guard target.hasPrefix(prefix) else { return nil }
        return "/" + target.dropFirst(prefix.count)
    }

    /// IPv4 address of the Wi-Fi (`en0`) interface, falling back to any other
    /// active `en*` interface (Ethernet adapters on iPad).
    nonisolated static func localNetworkIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var fallback: String?
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & (IFF_UP | IFF_RUNNING) == (IFF_UP | IFF_RUNNING),
                  flags & IFF_LOOPBACK == 0,
                  let addr = entry.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            if name == "en0" { return address }
            if fallback == nil { fallback = address }
        }
        return fallback
    }

    // MARK: - Request processing

    private func processHTTPRequest(_ data: Data, connection: NWConnection) async {
        guard let requestString = String(data: data, encoding: .utf8) else {
            connection.cancel()
            return
        }

        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            connection.cancel()
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            connection.cancel()
            return
        }

        let method = String(parts[0])
        guard method == "GET" || method == "HEAD" else {
            Self.sendError(connection, code: 405)
            return
        }
        guard let path = Self.upstreamPath(forRequestTarget: String(parts[1]), secret: pathSecret) else {
            Self.sendError(connection, code: 404)
            return
        }

        // Extract Range header
        var rangeHeader: String?
        for line in lines.dropFirst() {
            if line.lowercased().hasPrefix("range:") {
                rangeHeader = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                break
            }
        }

        // Build upstream URL
        let baseStr = serverBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let upstreamURL = URL(string: baseStr + path) else {
            connection.cancel()
            return
        }

        var request = URLRequest(url: upstreamURL)
        request.httpMethod = method
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        if let rangeHeader {
            request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        }

        // Stream response to avoid loading entire video into memory.
        //
        // `streamer` is created OUTSIDE the `do` and the upstream is cancelled in
        // `defer`, so the cancel covers every exit — including the `guard
        // headerSent else { return }` below, which sits before the body loop and
        // has no `try` boundary of its own.
        //
        // `StreamingSession.onTermination` cannot be relied on here: it fires when
        // the stream object is dropped, whereas this relay notices a dead peer via a
        // failed `NWConnection.send`. A peer that merely stops reading (an AirPlay
        // receiver scrubbing away) fails no send at all — it parks the loop while the
        // upstream keeps streaming a whole video to nobody, with
        // `timeoutIntervalForResource = 0`.
        let streamer = StreamingSession()
        defer { streamer.cancelUpstream() }
        do {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 0
            config.timeoutIntervalForResource = 0

            let (httpResponse, chunks) = try await streamer.stream(request: request, configuration: config)

            // Build response header
            var header = "HTTP/1.1 \(httpResponse.statusCode)"
            if let reason = Self.statusReason(httpResponse.statusCode) {
                header += " \(reason)"
            }
            header += "\r\n"

            let passHeaders = ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges"]
            for key in passHeaders {
                if let value = httpResponse.value(forHTTPHeaderField: key) {
                    header += "\(key): \(value)\r\n"
                }
            }
            header += "Connection: close\r\n\r\n"

            // Send header
            let headerSent = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                connection.send(content: header.data(using: .utf8), completion: .contentProcessed { error in
                    cont.resume(returning: error == nil)
                })
            }
            guard headerSent else {
                connection.cancel()
                return
            }

            // Stream body — chunks arrive as Data from delegate, forward directly
            let sendChunkSize = Self.sendChunkSize
            var buffer = Data()
            var downstreamGone = false
            for try await chunk in chunks {
                buffer.append(chunk)
                while buffer.count >= sendChunkSize {
                    let sendData = Data(buffer.prefix(sendChunkSize))
                    buffer = Data(buffer.dropFirst(sendChunkSize))
                    let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                        connection.send(content: sendData, completion: .contentProcessed { error in
                            cont.resume(returning: error == nil)
                        })
                    }
                    if !ok {
                        // Downstream is gone. Stop draining the upstream rather
                        // than pulling the next 256 KB for a peer that is not
                        // there; the outer `defer` cancels the request.
                        connection.cancel()
                        downstreamGone = true
                        break
                    }
                }
                if downstreamGone { break }
            }

            // Downstream failure: nothing to flush, no final message to send.
            guard !downstreamGone else { return }

            // Flush remaining
            if !buffer.isEmpty {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    connection.send(content: buffer, completion: .contentProcessed { _ in
                        cont.resume()
                    })
                }
            }

            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } catch {
            Self.logger.error("Stream error: \(error.localizedDescription)")
            Self.sendError(connection, code: 502)
        }
    }

    /// Body bytes buffered/aggregated per `connection.send` while relaying an
    /// upstream chunk. Exposed for tests that assert the buffer stays bounded
    /// regardless of how the upstream delivers its bytes.
    nonisolated static let sendChunkSize = 256 * 1024

    private nonisolated static func sendError(_ connection: NWConnection, code: Int) {
        let response = "HTTP/1.1 \(code) Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func statusReason(_ code: Int) -> String? {
        switch code {
        case 200: "OK"
        case 206: "Partial Content"
        case 301: "Moved Permanently"
        case 302: "Found"
        case 304: "Not Modified"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 416: "Range Not Satisfiable"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        default: nil
        }
    }
}

/// The surface `VideoDetailViewModel` needs from its streaming proxy.
///
/// Conforming in a protocol extension (rather than declaring conformance on
/// `AuthProxy`) keeps this seam additive: `AuthProxy`'s own method signatures
/// stay free of `any ...` return types, and a fake only has to implement these
/// four members. `AuthProxy` satisfies it structurally.
///
/// Exists so tests can substitute a fake with a slow, observable bind and drive
/// the abandon-mid-bind contract in `startAuthProxy` / `stopAuthProxy` without a
/// real `NWListener`. `AuthProxy` is the only production conformer, and
/// `proxyFactory` returns this type so a subclass cannot be widened by accident.
protocol AuthProxyConsumeProtocol: Actor {
    func start() async throws
    func stop()
    func proxyURL(for originalURL: URL) -> URL?
    func networkURL(for originalURL: URL) -> URL?
}

/// Owns a proxy on its way out and guarantees `stop()` runs exactly once,
/// without the caller having to `await`.
///
/// `AuthProxy` is an actor, so `stop()` is asynchronous — and the teardown paths
/// that need it are the ones that cannot await: `VideoDetailViewModel.stopPlayback()`
/// is synchronous and is also reached from a `nonisolated` `deinit`, where there
/// is no way to touch MainActor state or suspend. An unowned
/// `Task { await proxy.stop() }` was the whole gap: nothing could cancel it, it
/// could land after a successor installed a different proxy, and when `deinit`
/// released the ViewModel there was no guarantee it ran at all — leaving the
/// `NWListener` bound with the user's token inside it for the life of the process.
///
/// The lease closes that gap by making the pending stop an *object* the owner can
/// see (`hasPendingTeardown`) and hand to whoever can finish it.
///
/// Two invariants carry the whole design; every method below exists to keep them
/// true under concurrent callers:
///
/// 1. **Single owner.** Exactly one path ever dispatches the effective `stop()`
///    for a socket: the lease's own stop task, the external taker, or (after an
///    `adopt()`) the lease itself once the bind task that owned the socket has
///    finished. The proxy reference leaves `proxy` exactly once.
/// 2. **Nothing observable as outstanding without something to join it.**
///    `.stopping` always names a live task in `_stoppingTask` (claim + install are
///    one synchronous section), and `.adopted` is joined by the call site that
///    created the bind task. A lost or placeholder task is exactly what hung
///    `awaitStopping()`: the waiter awaits an already-finished task, re-reads, sees
///    the same finished task, and never progresses.
///
/// Isolation: `nonisolated final class … : @unchecked Sendable` (see
/// `AcceptedConnections` for why this form and not per-member `nonisolated`). It is
/// load-bearing rather than stylistic: the entire purpose of the lease is to be
/// reachable from a `nonisolated` `VideoDetailViewModel.deinit` and from
/// Network/actor callbacks without a MainActor hop.
nonisolated final class AuthProxyLease: @unchecked Sendable {
    enum State: Sendable {
        /// Created, not yet stopping. A `deinit` that finds the lease in this
        /// state takes it over.
        case pending
        /// `stop()` has been dispatched. `_stoppingTask` names that task: the claim
        /// and the install share one synchronous critical section, so this state is
        /// never observable with a nil or stale task.
        case stopping
        /// `stop()` completed.
        case stopped
        /// The proxy was handed to a bind task that owns the socket; the lease
        /// stops it only if that task ends without doing so.
        ///
        /// This state may last as long as the owner task runs, so it is NOT "work is
        /// done". The lease holds NO task for it and NO reference to the owner:
        /// joining the owner is the call site's job (it holds the `Task`), and
        /// `awaitStopping()` then finishes the handoff via `finishAdoption()` —
        /// `Task` is not class-constrained, so the lease could not store or compare
        /// one anyway. An earlier design installed a watcher task into
        /// `_stoppingTask` here, and that shared slot was the hang: the watcher's
        /// install happened after an `await`, so a peer could nil or replace the
        /// slot in between and strand the real stop task.
        case adopted
        /// `takeForExternalStop()` handed the proxy to a taker (a `deinit`) that runs
        /// the stop itself, so the lease has no task of its own and nothing to join.
        ///
        /// A distinct state rather than `.stopping` with a placeholder task: a
        /// placeholder (`Task {}`) is immediately complete, so a waiter would await
        /// it, re-read, see the same placeholder, and await again forever. A no-op
        /// task is not a substitute for "there is nothing here to await", and the
        /// type says so instead of lying with a finished task.
        case claimedExternally
    }

    /// Separate category so a broken lease invariant is greppable in device logs.
    static let leakLogger = Logger(subsystem: "ru.mzhukov.TAClient", category: "AuthProxyLease")
    private let lock = NSLock()
    private var _state: State = .pending
    /// Both lock-guarded. Plain stored properties — the class-level `nonisolated`
    /// covers them, so `nonisolated(unsafe)` is neither needed nor wanted.
    private var proxy: (any AuthProxyConsumeProtocol)?
    private var _stoppingTask: Task<Void, Never>?

    init(proxy: any AuthProxyConsumeProtocol) {
        self.proxy = proxy
    }

    var state: State {
        lock.withLock { _state }
    }

    /// `true` while a stop has been dispatched but not confirmed.
    var isStoppingOrStopped: Bool {
        lock.withLock {
            // `.claimedExternally` counts: the stop is owned and dispatched by the
            // taker, so no second stop should be started for this socket.
            if case .pending = _state { return false }
            return true
        }
    }

    /// Dispatch `stop()` unless someone already has. Idempotent: a call that does
    /// not win the claim returns `nil` and touches no state.
    ///
    /// The claim, the state change and the task install happen in ONE synchronous
    /// critical section, so `.stopping` is never observable with a nil or stale
    /// `_stoppingTask`. No placeholder task, no install-after-`await`, no window for
    /// a second caller to clear the slot: an earlier revision nil'd `_stoppingTask`
    /// from a losing call while the winner was between claim and install, which
    /// stranded the live stop task and hung `awaitStopping()`.
    ///
    /// `Task.init` only schedules, so running it under the lock dispatches nothing
    /// before the section releases — the stop still cannot observe the lease mid-claim.
    @discardableResult
    func startStopping() -> Task<Void, Never>? {
        let task: Task<Void, Never>? = lock.withLock {
            guard case .pending = _state else { return nil }
            _state = .stopping
            // The lease stops owning the proxy reference the moment the stop is
            // claimed: from here only the stop task (or an external taker) holds
            // it, so a `deinit` cannot resurrect a second stop for the same socket.
            let held = proxy
            proxy = nil
            // Nothing left to stop — a handoff already moved the proxy out. Settle
            // instead of leaving `.stopping` pointing at a task that never comes.
            guard let held else {
                _state = .stopped
                return nil
            }
            let task = Task { [weak self] in
                await held.stop()
                self?.markStopped()
            }
            _stoppingTask = task
            return task
        }
        return task
    }

    /// Hand the socket to the bind task that is responsible for stopping it. The
    /// lease stays as a backstop: if that task finishes without stopping (it handed
    /// the proxy to someone else, or was cancelled between its install decision and
    /// its own `stop()`), the lease finishes the job — see `finishAdoption()`.
    ///
    /// No parameter, and that is deliberate. The owner task cannot be stored here:
    /// `Task` is not class-constrained, so it has no identity to compare and cannot
    /// be kept as `AnyObject`; and the watcher that used to wait on it had to write
    /// itself into `_stoppingTask` after an `await`, which is the race that hung
    /// `awaitStopping()`. The call site already holds the task — it just created it
    /// — so joining it there costs nothing and shares no state.
    func adopt() {
        lock.withLock {
            guard case .pending = _state else { return }
            _state = .adopted
        }
    }

    /// Take the lease away from its owner so a `deinit` can finish the stop
    /// itself. Returns `nil` when the stop is already dispatched or completed —
    /// i.e. when there is nothing left for a taker to do.
    ///
    /// The claim moves the lease to `.claimedExternally`, which `awaitStopping()`
    /// reports as "nothing on this lease to join" — the taker owns the stop and the
    /// lease genuinely holds no task for it. The previous design installed a no-op
    /// task to make a concurrent waiter return promptly; that inverted the failure
    /// mode and hung the waiter forever instead (see the state's comment).
    ///
    /// A caller that must wait for the socket belongs to the taker, not the lease:
    /// `deinit` cannot await at all, which is why it takes the proxy and stops it on
    /// a detached task it owns.
    func takeForExternalStop() -> (any AuthProxyConsumeProtocol)? {
        lock.withLock {
            // Only an unclaimed lease has something to hand out. A taker must never
            // receive the proxy after a stop was dispatched or the socket was adopted,
            // and a settled lease holds nil anyway.
            guard case .pending = _state else { return nil }
            let taken = proxy
            proxy = nil
            _state = .claimedExternally
            return taken
        }
    }

    /// Await the stop this lease is responsible for: the dispatched
    /// `startStopping()` task, or — after an `adopt()` whose owner task the caller
    /// has already joined — the backstop stop. For tests and for any caller that
    /// must not proceed until the socket is actually released.
    ///
    /// Termination is structural: every path either returns or awaits a task that
    /// cannot outlive the stop it stands for.
    /// - `.stopping` joins the stop task, installed by the claim synchronously.
    /// - `.adopted` dispatches the backstop and joins it.
    /// - `.pending` / `.claimedExternally` mean the lease owes nothing: an owner
    ///   that never claimed, or a taker that owns the stop on a task of its own.
    func awaitStopping() async {
        while true {
            let snapshot = lock.withLock { (state: _state, task: _stoppingTask) }
            switch snapshot.state {
            case .stopped, .pending, .claimedExternally:
                return
            case .adopted:
                if let stopTask = finishAdoption() {
                    await stopTask.value
                }
                return
            case .stopping:
                // `startStopping()`/`finishAdoption()` install the task inside the
                // same critical section that sets `.stopping`, so nil here is a
                // broken invariant rather than a transient. Log it loudly and return
                // — never spin: a socket already torn down is not worth a hung caller.
                guard let task = snapshot.task else {
                    Self.leakLogger.error("AuthProxyLease is .stopping with no stop task installed")
                    return
                }
                await task.value
            }
        }
    }

    /// Adopted path: claim the socket and dispatch the backstop `stop()` after a
    /// grace window, returning the task so a caller that must not proceed until the
    /// socket is released can join it. Returns `nil` when this lease is no longer
    /// `.adopted` (a concurrent finish/stop already owns the socket — that path owes
    /// the join).
    ///
    /// Claim and install happen in one synchronous section, and the grace window
    /// runs inside the task, so nothing can take the socket between this call and
    /// the stop.
    ///
    /// Callers that only need the guarantee can ignore the result: the stop is
    /// dispatched either way, and the lease's state advances to `.stopped`.
    @discardableResult
    func finishAdoption() -> Task<Void, Never>? {
        let task: Task<Void, Never>? = lock.withLock {
            guard case .adopted = _state else { return nil }
            // Claim synchronously, ahead of the grace window.
            let held = proxy
            proxy = nil
            _state = .stopping
            guard let held else {
                _state = .stopped
                return nil
            }
            let task = Task { [weak self] in
                // Grace window: give the owning bind task's own `stop()` a chance to
                // land on the actor first, so a normal handoff is not raced by a
                // redundant queued dispatch.
                try? await Task.sleep(for: Self.adoptedBackstopGrace)
                await held.stop()
                self?.markStopped()
            }
            _stoppingTask = task
            return task
        }
        return task
    }

    /// Grace the adopted backstop waits before stopping, so the owning bind task's
    /// own `stop()` lands first and a normal handoff is not raced by a redundant
    /// dispatch. `internal static` so tests bound their waits off the constant
    /// instead of hardcoding a duration.
    static let adoptedBackstopGrace = Duration.milliseconds(100)

    private func markStopped() {
        lock.withLock {
            if case .stopping = _state { _state = .stopped }
            proxy = nil
        }
    }
}

extension AuthProxyLease {
    /// Nonisolated view of the pending stop, for `deinit` and for tests.
    ///
    /// `VideoDetailViewModel.deinit` runs without actor isolation and therefore
    /// cannot read `authProxy`. It can read this, because the lease is
    /// `Sendable` and its state sits behind an `NSLock` — the same pattern the
    /// codebase already uses for lock-guarded `nonisolated(unsafe)` state that
    /// crosses the MainActor boundary.
    var hasPendingTeardown: Bool {
        lock.withLock {
            if case .pending = _state { return proxy != nil }
            // `.adopted` is deliberately NOT reported as pending: the socket has a
            // live bind task and the lease has a backstop for it. Reporting it
            // pending would invite a `deinit` to take a lease whose owner is still
            // running, giving one socket two owners. `.stopping`/`.stopped` are
            // likewise not pending.
            return false
        }
    }
}

extension AuthProxy: AuthProxyConsumeProtocol {}
