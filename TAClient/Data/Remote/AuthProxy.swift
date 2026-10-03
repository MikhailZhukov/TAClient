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
/// `nonisolated` is required, not stylistic: `@unchecked Sendable` alone does not
/// escape this target's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and without it
/// every member would be MainActor-isolated and uncallable from those framework
/// queues. Same convention as `CacheStore`.
nonisolated final class AcceptedConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private(set) var isShutdown = false

    nonisolated init(isShutdown: Bool = false) {
        self.isShutdown = isShutdown
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
    nonisolated func install(_ connection: NWConnection) -> Bool {
        let tracked = lock.withLock { () -> Bool in
            guard !isShutdown else { return false }
            connections[ObjectIdentifier(connection)] = connection
            return true
        }
        if tracked {
            connection.stateUpdateHandler = { state in
                switch state {
                case .cancelled, .failed:
                    cancelAndRelease(connection)
                default:
                    break
                }
            }
        }
        return tracked
    }

    nonisolated func release(_ connection: NWConnection) {
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
    nonisolated func shutdown() {
        let pending = lock.withLock { () -> [NWConnection] in
            isShutdown = true
            return Array(connections.values)
        }
        for connection in pending { connection.cancel() }
    }

    /// Drop a connection the framework reports as terminal, so a tracker that
    /// outlives its proxy (Network.framework keeps the connection alive until
    /// the close completes) does not pin dead peers indefinitely.
    nonisolated func cancelAndRelease(_ connection: NWConnection) {
        let known = lock.withLock { () -> Bool in
            guard connections[ObjectIdentifier(connection)] != nil else { return false }
            connections[ObjectIdentifier(connection)] = nil
            return true
        }
        if known { connection.cancel() }
    }

    nonisolated var count: Int {
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
    /// Set by `stop()` so a late `.failed` callback from the listener being
    /// torn down cannot resurrect the proxy through `restartListener()`.
    /// `NWListener.cancel()` is asynchronous, so that callback really can land
    /// after `stop()` has already returned.
    private var isStopped = false
    /// Shutdown flag plus the set of connections accepted by the current
    /// listener. `stop()` flips it and cancels everything still in flight, so
    /// no per-request streaming task survives the proxy that authorised it.
    private var acceptedConnections: AcceptedConnections?

    var localPort: UInt16 { port }

    init(token: String, serverBaseURL: URL) {
        self.token = token
        self.serverBaseURL = serverBaseURL
    }

    func start() async throws {
        let params = NWParameters.tcp
        #if !targetEnvironment(simulator)
        // The simulator's host network stack rejects even 127.0.0.1 peers under
        // acceptLocalOnly, so the flag only applies on devices.
        params.acceptLocalOnly = true
        #endif
        let listener = try NWListener(using: params, on: .any)

        // A restart re-enters `start()` after `restartListener()` shut the
        // previous tracker down; inheriting that shutdown flag would make the
        // freshly bound listener refuse every connection. A first `start()` on a
        // proxy that was already stopped keeps the flag set, so its handler
        // refuses connections until the (cancelled) bind resolves.
        let accepted = AcceptedConnections(isShutdown: isStopped)
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
        let startingStateHandler: @Sendable (NWListenerState) -> Void = { [box] state in
            switch state {
            case .ready:
                box.set(listener.port?.rawValue ?? 0)
            case .failed(let error):
                Self.logger.error("Listener failed while starting: \(error.localizedDescription)")
            default:
                break
            }
        }
        // Install before `start()`, then poll for `.ready` instead of parking a
        // `CheckedContinuation` on it. The continuation form had no way to be
        // handed back: a caller cancelled (or a timeout) while `start()` was
        // suspended left a continuation that nothing could resume, and the
        // state handler captured the continuation closure — which retains the
        // listener — installed on that listener forever.
        listener.stateUpdateHandler = startingStateHandler
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
            listener.cancel()
            throw AppError.unknown(message: "AuthProxy failed to bind")
        }
        // A `stop()` that landed while `start()` was polling has already
        // cancelled this listener; do not hand a dead socket back to the caller
        // (and do not reinstall a state handler on it).
        guard !isStopped else {
            throw AppError.unknown(message: "AuthProxy stopped while starting")
        }

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
    }

    /// Rebind after a transport failure. A failed listener is already dead,
    /// so there is nothing to cancel here — cancelling it used to route
    /// through the same path as `stop()` and left the old listener's async
    /// `.cancelled` callback racing the new one.
    func restartListener() {
        guard !isStopped, listener != nil else { return }
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
        guard !isStopped else { return }
        isStopped = true
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
/// `nonisolated` is load-bearing, not stylistic: the whole point is that a
/// `nonisolated` `deinit` and Network/actor callbacks can reach it without a
/// MainActor hop, and `@unchecked Sendable` alone does not escape this target's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — members would be inferred MainActor
/// and the deinit could not call them. Same convention as `CacheStore`.
nonisolated final class AuthProxyLease: @unchecked Sendable {
    enum State: Sendable {
        /// Created, not yet stopping. A `deinit` that finds the lease in this
        /// state takes it over.
        case pending
        /// `stop()` has been dispatched. Nobody else needs to do anything.
        case stopping
        /// `stop()` completed.
        case stopped
        /// The proxy was handed to a bind task that owns the socket; the lease
        /// stops it only if that task ends without doing so.
        case adopted(Task<Void, Never>)
    }

    private let lock = NSLock()
    private var _state: State = .pending
    nonisolated(unsafe) private var proxy: (any AuthProxyConsumeProtocol)?
    nonisolated(unsafe) private var _stoppingTask: Task<Void, Never>?

    nonisolated init(proxy: any AuthProxyConsumeProtocol) {
        self.proxy = proxy
    }

    nonisolated var state: State {
        lock.withLock { _state }
    }

    /// `true` while a stop has been dispatched but not confirmed.
    nonisolated var isStoppingOrStopped: Bool {
        lock.withLock {
            if case .pending = _state { return false }
            return true
        }
    }

    /// Dispatch `stop()` unless someone already has. Idempotent.
    ///
    /// The work runs in a task stored on the lease, not a floating one, so
    /// `awaitStopping()` (tests) and any future coordinator can join it instead
    /// of polling a counter or guessing a sleep.
    @discardableResult
    nonisolated func startStopping() -> Task<Void, Never>? {
        // Claim the proxy and flip the state in one critical section, then create
        // the task OUTSIDE the lock. Two invariants that cannot both be satisfied
        // by "just build the task inside the lock":
        //
        // - `_stoppingTask` must never be observable as nil while the state is
        //   `.stopping`, or `awaitStopping()` returns without joining anything;
        // - the critical section must not call out to code we do not own.
        //
        // So the task is built after the claim, but the claim is expressed as
        // `_stoppingTask = placeholder` FIRST and overwritten immediately, which
        // keeps the first invariant. `Task.init` only schedules — it does not run
        // the body — so the placeholder is never awaited for real work.
        let claim: (any AuthProxyConsumeProtocol)? = lock.withLock {
            guard case .pending = _state else { return nil }
            _stoppingTask = Task<Void, Never> { }
            _state = .stopping
            let claimed = proxy
            // The lease stops owning the proxy reference the moment the stop is
            // claimed: from here only the stop task (or an external taker) holds
            // it, so a `deinit` cannot resurrect a second stop for the same socket.
            proxy = nil
            return claimed
        }
        guard let claim else { return nil }
        let task = Task { [weak self] in
            await claim.stop()
            self?.markStopped()
        }
        lock.withLock { if case .stopping = _state { _stoppingTask = task } }
        return task
    }

    /// Hand the socket to a bind task that will stop it after its own
    /// suspension. The lease stays as a backstop: if that task ends without
    /// stopping (it returned a proxy somebody else adopted, or was cancelled
    /// between the install decision and the stop), the lease finishes the job.
    nonisolated func adopt(installedBy task: Task<Void, Never>) {
        let adopted: Task<Void, Never>? = lock.withLock {
            guard case .pending = _state else { return nil }
            _state = .adopted(task)
            return task
        }
        guard let adopted else { return }
        // Created under the lock for the same reason as `startStopping`: the
        // watcher must be joinable via `awaitStopping()` from the moment it exists.
        lock.withLock {
            guard case .adopted = _state else { return }
            let watcher = Task { [weak self] in
                _ = await adopted.value
                // Give the owning task's own `stop()` a chance to land on the actor
                // first, so a normal handoff does not queue a redundant stop.
                try? await Task.sleep(for: .milliseconds(100))
                self?.startStopping()
            }
            _stoppingTask = watcher
        }
    }

    /// Take the lease away from its owner so a `deinit` can finish the stop
    /// itself. Returns `nil` when the stop is already dispatched or completed —
    /// i.e. when there is nothing left for a taker to do.
    ///
    /// The claim also installs a no-op `_stoppingTask`, so a concurrent
    /// `awaitStopping()` joins something that completes rather than observing
    /// `.stopping` with an empty slot and returning early — a caller waiting for
    /// "the socket is released" would otherwise be told "done" while an external
    /// stop is still in flight. The taker owns the real stop.
    nonisolated func takeForExternalStop() -> (any AuthProxyConsumeProtocol)? {
        lock.withLock {
            guard case .pending = _state else {
                proxy = nil
                return nil
            }
            let taken = proxy
            proxy = nil
            _stoppingTask = Task<Void, Never> { }
            _state = .stopping
            return taken
        }
    }

    /// Await the dispatched stop, if one is in flight. For tests and for any
    /// caller that must not proceed until the socket is actually released.
    ///
    /// Loops because of the adopted branch: while the lease waits on its owner
    /// task, `_stoppingTask` holds that watcher, and the watcher's own
    /// `startStopping()` replaces it with the real stop task. Re-reading until the
    /// state is terminal keeps this correct without exposing the intermediate.
    nonisolated func awaitStopping() async {
        while true {
            let snapshot = lock.withLock { (state: _state, task: _stoppingTask) }
            if case .stopped = snapshot.state { return }
            // `.pending` with no task: nobody has claimed the lease. Nothing to
            // join — the owner (or `deinit`) still owes the stop.
            guard let task = snapshot.task else { return }
            await task.value
            // Loop re-reads: an adopted watcher ends by calling `startStopping()`,
            // which installs the REAL stop task in `_stoppingTask`. The loop exits
            // on `.stopped`, so it cannot spin — every pass either returns or
            // awaits a strictly later task.
        }
    }

    nonisolated private func markStopped() {
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
    nonisolated var hasPendingTeardown: Bool {
        lock.withLock {
            if case .pending = _state { return proxy != nil }
            return false
        }
    }
}

extension AuthProxy: AuthProxyConsumeProtocol {}
