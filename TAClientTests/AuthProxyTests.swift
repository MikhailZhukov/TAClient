import Testing
import Foundation
import Network
@testable import TAClient

/// The auth proxy listens on the local network (AirPlay receivers must reach
/// it), so every URL carries a per-instance path secret and requests without
/// it must never reach the server with the user's token.
struct AuthProxyTests {

    // MARK: - upstreamPath

    @Test func upstreamPath_withSecret_stripsSecret() {
        let path = AuthProxy.upstreamPath(forRequestTarget: "/abc/media/UC1/vid.mp4?x=1", secret: "abc")
        #expect(path == "/media/UC1/vid.mp4?x=1")
    }

    @Test func upstreamPath_withoutSecret_isRejected() {
        #expect(AuthProxy.upstreamPath(forRequestTarget: "/media/UC1/vid.mp4", secret: "abc") == nil)
    }

    @Test func upstreamPath_wrongSecret_isRejected() {
        #expect(AuthProxy.upstreamPath(forRequestTarget: "/abd/media/vid.mp4", secret: "abc") == nil)
    }

    @Test func upstreamPath_secretWithoutTrailingSlash_isRejected() {
        #expect(AuthProxy.upstreamPath(forRequestTarget: "/abcmedia/vid.mp4", secret: "abc") == nil)
        #expect(AuthProxy.upstreamPath(forRequestTarget: "/abc", secret: "abc") == nil)
    }

    @Test func upstreamPath_absoluteFormTarget_isRejected() {
        let target = "http://evil.example.com/abc/media/vid.mp4"
        #expect(AuthProxy.upstreamPath(forRequestTarget: target, secret: "abc") == nil)
    }

    // MARK: - URLs

    @Test func proxyURL_beforeStart_isNil() async {
        let proxy = AuthProxy(token: "t", serverBaseURL: URL(string: "https://ta.example.com")!)
        let url = await proxy.proxyURL(for: URL(string: "https://ta.example.com/media/vid.mp4")!)
        #expect(url == nil)
    }

    @Test func proxyURL_isLoopbackWithSecretPrefixAndQuery() async throws {
        let proxy = AuthProxy(token: "t", serverBaseURL: URL(string: "https://ta.example.com")!)
        try await proxy.start()
        defer { Task { await proxy.stop() } }

        let original = URL(string: "https://ta.example.com/media/UC1/vid%20a.mp4?x=1")!
        let url = try #require(await proxy.proxyURL(for: original))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(components.scheme == "http")
        #expect(components.host == "127.0.0.1")
        #expect((components.port ?? 0) > 0)
        #expect(components.percentEncodedPath.hasSuffix("/media/UC1/vid%20a.mp4"))
        #expect(components.percentEncodedPath != "/media/UC1/vid%20a.mp4")
        #expect(components.percentEncodedQuery == "x=1")
    }

    @Test func networkURL_usesLocalNetworkHost() async throws {
        let proxy = AuthProxy(token: "t", serverBaseURL: URL(string: "https://ta.example.com")!)
        try await proxy.start()
        defer { Task { await proxy.stop() } }

        let original = URL(string: "https://ta.example.com/media/vid.mp4")!
        let url = await proxy.networkURL(for: original)
        if let address = AuthProxy.localNetworkIPv4Address() {
            #expect(url?.host == address)
            #expect(url?.path.hasSuffix("/media/vid.mp4") == true)
        } else {
            #expect(url == nil)
        }
    }

    // MARK: - Accepted-connection tracking

    /// `NWListener.cancel()` does not terminate connections it already
    /// accepted, and the per-request relay has no timeout, so `stop()` must
    /// cancel them itself or the relay task (and the token it forwards) keeps
    /// running after the proxy is gone.
    @Test func stop_cancelsInFlightConnections()
        async throws {
        let proxy = AuthProxy(token: "t", serverBaseURL: URL(string: "https://ta.example.com")!)
        try await proxy.start()

        let tracker = try #require(await proxy.acceptedConnectionsForTests)
        let connection = try #require(await proxy.openLoopbackConnectionForTests())
        guard tracker.count == 1 else {
            // The listener never registered the peer (sandboxed CI, no loopback
            // route). Bail loudly rather than asserting against an untracked
            // connection.
            Issue.record("loopback peer was not tracked by the listener; cannot exercise stop()")
            return
        }

        await proxy.stop()

        #expect(tracker.isShutdown, "stop() must refuse connections accepted afterwards")
        #expect(tracker.count == 0, "stop() must clear the tracker")
        // `NWConnection.cancel()` is async; poll briefly for the terminal state.
        var observed = connection.state
        for _ in 0..<100 where observed != .cancelled {
            try await Task.sleep(for: .milliseconds(20))
            observed = connection.state
        }
        #expect(observed == .cancelled, "stop() must cancel in-flight connections (state: \(observed))")
    }

    /// The tracker lives in `newConnectionHandler`, outside the actor's
    /// isolation domain, so the shutdown flag has to be observable there
    /// without an actor hop (an `await` in that callback would re-open the
    /// window `stop()` is meant to close).
    @Test func acceptedConnections_shutdownFlagIsVisibleWithoutActorHop() {
        let tracker = AcceptedConnections()
        #expect(!tracker.isShutdown)
        tracker.shutdown()
        #expect(tracker.isShutdown)
        // Idempotent and still refusing after a second shutdown.
        tracker.shutdown()
        #expect(tracker.isShutdown)
        #expect(tracker.count == 0)
    }

    /// A tracker built for a proxy that was already stopped must refuse
    /// connections from birth; a restart must get a live one.
    @Test func acceptedConnections_inheritsShutdownState() {
        #expect(AcceptedConnections(isShutdown: true).isShutdown)
        #expect(!AcceptedConnections().isShutdown)
    }

    // MARK: - Rebind guard

    /// A `.failed` callback queued before `stop()` can land after it, because
    /// `NWListener.cancel()` is asynchronous. It must not resurrect the proxy.
    @Test func restartListener_afterStop_doesNotRebind() async throws {
        let proxy = AuthProxy(token: "t", serverBaseURL: URL(string: "https://ta.example.com")!)
        try await proxy.start()
        let port = await proxy.localPort
        #expect(port > 0)

        await proxy.stop()
        await proxy.restartListener()

        // Give the fire-and-forget rebind every chance to happen.
        try await Task.sleep(for: .milliseconds(300))
        #expect(await proxy.localPort == 0, "restartListener() must be a no-op after stop()")
    }

    @Test func restartListener_withoutListener_isNoOp() async {
        let proxy = AuthProxy(token: "t", serverBaseURL: URL(string: "https://ta.example.com")!)
        await proxy.restartListener()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await proxy.localPort == 0)
    }

    // MARK: - Start teardown

    /// A cancelled `start()` must not leave a bound socket behind — the old
    /// continuation form had no way to unwind, so the listener stayed bound and
    /// kept its state handler until process exit.
    @Test func cancelledStart_doesNotLeaveListenerBound() async throws {
        let proxy = AuthProxy(token: "t", serverBaseURL: URL(string: "https://ta.example.com")!)
        let task = Task {
            try? await proxy.start()
        }
        // Cancel almost immediately, before the bind can reliably complete.
        try await Task.sleep(for: .milliseconds(1))
        task.cancel()
        _ = await task.value

        #expect(await proxy.localPort == 0, "cancelled start() must not report a bound port")
        let url = await proxy.proxyURL(for: URL(string: "https://ta.example.com/media/vid.mp4")!)
        #expect(url == nil)
    }

    /// `stop()` twice is a no-op the second time, and a `stop()` on a proxy that
    /// never started must not trap.
    @Test func stop_isIdempotent() async throws {
        let proxy = AuthProxy(token: "t", serverBaseURL: URL(string: "https://ta.example.com")!)
        // `stop()` before `start()` must not trap and must mark the proxy dead.
        await proxy.stop()
        try await proxy.start()
        await proxy.stop()
        await proxy.stop()
        #expect(await proxy.localPort == 0)
        // A `start()` on a stopped proxy must refuse connections from birth.
        let stopped = AuthProxy(token: "t", serverBaseURL: URL(string: "https://ta.example.com")!)
        await stopped.stop()
        try? await stopped.start()
        #expect(await stopped.acceptedConnectionsForTests?.isShutdown == true)
    }

    // MARK: - Request rejection

    @Test func requestWithoutSecret_isRefusedWith404() async throws {
        let proxy = AuthProxy(token: "t", serverBaseURL: URL(string: "https://ta.example.com")!)
        try await proxy.start()
        defer { Task { await proxy.stop() } }

        let port = await proxy.localPort
        let bare = URL(string: "http://127.0.0.1:\(port)/media/vid.mp4")!
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let (_, response) = try await session.data(from: bare)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
    }
}

// MARK: - Test seams

extension AuthProxy {
    /// The live connection tracker, for asserting `stop()` shuts it down.
    var acceptedConnectionsForTests: AcceptedConnections? {
        acceptedConnections
    }

    /// Open a real loopback connection through the running listener so the
    /// tracker has something to cancel. Returns `nil` when the listener is not
    /// ready or the peer cannot connect (sandboxed CI, no loopback route).
    func openLoopbackConnectionForTests() -> NWConnection? {
        guard port > 0 else { return nil }
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let ready = SendableBox<Bool>(false)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.set(true)
            case .failed, .cancelled:
                ready.set(false)
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))

        // The listener's `newConnectionHandler` runs on a Network.framework
        // queue, so wait for the tracker to register the peer rather than
        // racing it.
        var deadline = 100
        while !ready.current && deadline > 0 {
            Thread.sleep(forTimeInterval: 0.01)
            deadline -= 1
        }
        guard ready.current else {
            connection.cancel()
            return nil
        }
        var trackedDeadline = 100
        while acceptedConnections?.count == 0 && trackedDeadline > 0 {
            Thread.sleep(forTimeInterval: 0.01)
            trackedDeadline -= 1
        }
        return connection
    }
}
