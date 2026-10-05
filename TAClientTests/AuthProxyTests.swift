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
    @Test func stop_cancelsInFlightConnections() async throws {
        let proxy = AuthProxy(token: "t", serverBaseURL: URL(string: "https://ta.example.com")!)
        try await proxy.start()

        // The seam opens a real loopback peer and returns only once the actor's
        // tracker has counted it, or nil when loopback is unavailable in this
        // sandbox — in which case there is nothing to exercise and the test must
        // not assert against an untracked connection.
        guard let connection = await proxy.openLoopbackConnectionForTests() else {
            Issue.record("loopback peer could not be opened/tracked; cannot exercise stop()")
            return
        }
        #expect(await proxy.trackedConnectionCountForTests() == 1)

        await proxy.stop()

        #expect(await proxy.trackedConnectionCountForTests() == -1,
                "stop() must drop the tracker entirely (-1 == no tracker)")

        #expect(await proxy.localPort == 0, "stop() must release the port")

        // What the peer's `NWConnection.state` can and cannot tell us.
        //
        // `connection` is the test's CLIENT-side peer. The tracker — and therefore
        // `stop()` — holds the LISTENER-side connection the listener accepted: a
        // different NWConnection object on the far end of the same socket. So the
        // peer's state is not an observable of what `stop()` did:
        //   - it can never become `.cancelled`, because nobody calls `cancel()` on it;
        //   - it can legitimately stay `.ready` even after the far end is closed,
        //     because a TCP client with no I/O outstanding has no reason to notice.
        //     Reading a closed peer is what surfaces it (as `.waiting`/`.failed`), and
        //     polling `state` performs no I/O. Asserting on it was wrong twice over —
        //     first for `.cancelled`, then for `!= .ready`.
        //
        // The guarantee that matters is behavioural: after `stop()` the socket must
        // not serve another request. That is the leak this branch exists for (a relay
        // that keeps streaming, holding the user's token), and it is what the peer is
        // actually useful for — as a client that tries to keep using the proxy.
        let served = await TrySendThroughStoppedProxy.send(connection)
        #expect(!served,
                "a stopped proxy must not serve a request on a connection it accepted before stopping")

        connection.cancel()
    }

    /// The tracker holds each peer strongly so `shutdown()` has something to
    /// cancel, which means the tracker itself must stop holding connections the
    /// framework already finished with — otherwise a proxy that outlives its
    /// streams pins every peer until the next shutdown.
    @Test func tracker_releasesConnectionsOnceTerminal() {
        let tracker = AcceptedConnections()
        let connection = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
        // `install` arms a terminal-state handler, which retains the connection.
        // Asserting the map entry alone would not catch a handler that keeps the
        // connection alive after the entry is dropped.
        #expect(tracker.install(connection))
        #expect(tracker.count == 1)

        tracker.release(connection)
        #expect(tracker.count == 0)
        // Releasing an untracked connection must not install anything or throw.
        tracker.release(connection)
        #expect(tracker.count == 0)

        // A shut-down tracker refuses to track, so the caller can cancel.
        tracker.shutdown()
        #expect(!tracker.install(NWConnection(host: "127.0.0.1", port: 1, using: .tcp)))
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

    /// `AuthProxy.stop()` cancels the tracker and then drops its own reference,
    /// so a second `shutdown()` from a late framework callback still has to reach
    /// the connections rather than finding an emptied map.
    @Test func acceptedConnections_shutdownIsIdempotentAndKeepsPendingTargets() {
        let tracker = AcceptedConnections()
        let connection = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
        #expect(tracker.install(connection))

        tracker.shutdown()
        #expect(tracker.isShutdown)
        // Still tracked until reported terminal: the cancel is in flight.
        #expect(tracker.count == 1)
        tracker.shutdown()
        #expect(tracker.count == 1)

        tracker.cancelAndRelease(connection)
        #expect(tracker.count == 0)
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

    @Test func restartListener_withoutListener_isNoOp() async throws {
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

    /// `stop()` twice tears the socket down once, and a `stop()` on a proxy that
    /// never started must not trap.
    ///
    /// The guard is `listener != nil`, not a boolean: the boolean version returned
    /// before the teardown assignments, so a repeat `stop()` left `port` and the
    /// tracker live (the two failures this test used to record).
    @Test func stop_isIdempotent() async throws {
        let proxy = AuthProxy(token: "t", serverBaseURL: URL(string: "https://ta.example.com")!)
        // `stop()` before `start()` must not trap.
        await proxy.stop()
        // It must also NOT poison the instance: `start()` afterwards is a legal
        // sequence and binds normally. (An earlier revision of this test asserted the
        // opposite — that restarting a stopped proxy is refused — which was written
        // against a design where one `stop()` disabled the tracker permanently. That
        // design was a bug: it made a fresh instance stopped-before-start un-startable
        // for life, and the assertion was pinning the bug.)
        try await proxy.start()
        #expect(await proxy.localPort > 0, "start() after a pre-start stop() must bind")

        await proxy.stop()
        await proxy.stop()
        #expect(await proxy.localPort == 0)

        // What idempotency still guarantees: the proxy is dead once stopped, and its
        // tracker is gone rather than left live.
        #expect(await proxy.trackedConnectionCountForTests() == -1,
                "stop() must drop the tracker")

        // A fresh proxy that was never started has no tracker.
        let fresh = AuthProxy(token: "t", serverBaseURL: URL(string: "https://ta.example.com")!)
        #expect(await fresh.trackedConnectionCountForTests() == -1, "no tracker before start()")
    }

    /// The `stop()`-vs-bind hole, pinned at the observable surface.
    ///
    /// `stop()` used to bail on a boolean idempotency guard BEFORE clearing `port` /
    /// `acceptedConnections`, and `start()` installed its OWN tracker before the
    /// bind poll. So a `stop()` that no-ops — because it is the second call, or
    /// because the proxy was stopped before it ever started — let the bind publish a
    /// listener AND an armed tracker that no later `stop()` would ever release.
    ///
    /// Two interleavings, both must end with nothing live. Case 2 is the deterministic
    /// one (no timing dependence); case 1 is the same hole hit mid-poll.
    @Test func stopRacingBindLeavesNothingLive() async throws {
        let media = URL(string: "https://ta.example.com/media/vid.mp4")!
        let base = URL(string: "https://ta.example.com")!

        // Case 1: `stop()` lands while a bind is suspended in its poll.
        let racing = AuthProxy(token: "t", serverBaseURL: base)
        await racing.stop()
        let started = Task { try? await racing.start() }
        try await Task.sleep(for: .milliseconds(5))
        await racing.stop()
        _ = await started.value

        // Case 2: the bind published, and the stop that follows is the no-op-by-flag
        // one — under the old ordering it cleared nothing at all.
        let published = AuthProxy(token: "t", serverBaseURL: base)
        try await published.start()
        await published.stop()
        await published.stop()

        for proxy in [racing, published] {
            #expect(await proxy.localPort == 0, "no socket may outlive the stop")
            #expect(await proxy.trackedConnectionCountForTests() == -1,
                    "no tracker reference may outlive the stop")
            #expect(!(await proxy.hasLiveTrackerForTests),
                    "a stopped proxy must not hold an armed tracker")
            #expect(await proxy.proxyURL(for: media) == nil,
                    "a stopped proxy must not hand out a proxy URL")
        }
    }

    /// A stopped proxy is reusable: `start()` re-arms, and the fresh socket is then
    /// releasable by `stop()`. The old design either poisoned the instance (tracker
    /// refused everything for life) or left the new socket unstopped.
    @Test func startAfterStopIsLiveAndStoppable() async throws {
        let proxy = AuthProxy(token: "t", serverBaseURL: URL(string: "https://ta.example.com")!)
        await proxy.stop()
        try await proxy.start()
        #expect(await proxy.localPort > 0)
        #expect(await proxy.trackedConnectionCountForTests() != -1,
                "a live proxy must have a tracker")

        await proxy.stop()
        #expect(await proxy.localPort == 0)
        #expect(await proxy.trackedConnectionCountForTests() == -1)
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

/// Writes a request down the test's peer connection and reports whether anything
/// came back. Used by `stop_cancelsInFlightConnections` because the peer's
/// `NWConnection.state` is not an observable of the LISTENER-side cancel (see the
/// comment there): the only way to see that a stopped proxy stopped serving is to
/// ask it to serve.
///
/// Returns `false` on write failure, read failure, close, or timeout — every one of
/// those is a correct outcome for a stopped proxy. A `true` means the proxy answered
/// after `stop()`, which is the leak.
enum TrySendThroughStoppedProxy {
    static func send(_ connection: NWConnection) async -> Bool {
        // The connection is only guaranteed to have been started by the listener on
        // ITS side; the test's peer was started by the seam. Re-affirm, since a
        // connection that never reached `.ready` cannot answer either way.
        let request = "GET /nope HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        let answered = SendableBox<Bool>(false)
        let done = SendableBox<Bool>(false)
        
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled, .waiting:
                done.set(true)
            default:
                break
            }
        }
        connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
            if error != nil {
                done.set(true)
                return
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, err in
                if err == nil, let data, !data.isEmpty {
                    answered.set(true)
                }
                if isComplete || err != nil {
                    done.set(true)
                }
            }
        })

        // Bounded wait, mirroring the seam's own style: elapsed-vs-total rather than
        // Date arithmetic, so the exit condition reads as what it is.
        let started = Date()
        while !done.current && Date().timeIntervalSince(started) < 1.5 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return answered.current
    }
}
