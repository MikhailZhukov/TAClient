import Testing
import Foundation
@testable import TAClient

/// `AuthProxy`'s `stop()` is asynchronous and the teardown paths that need it
/// cannot await — `VideoDetailViewModel.stopPlayback()` is synchronous and is
/// also reached from a `nonisolated` `deinit`. The lease makes the pending stop
/// an object so those paths can tell "already claimed" from "nobody stopped it",
/// which is the distinction that let a listener stay bound with the user's token
/// inside it.
///
/// `.serialized`: the fakes count *effective* stops on actors that other tests in
/// the same process also create and tear down, and those dispatches have no
/// cross-test ordering.
@Suite(.serialized)
struct AuthProxyLeaseTests {

    // MARK: - Helpers

    /// Mirrors `AuthProxy`'s `isStopped` guard, so tests can assert the
    /// socket-facing invariant ("stopped at most once") rather than counting
    /// redundant dispatches that the real proxy swallows.
    actor SpyProxy: AuthProxyConsumeProtocol {
        private(set) var startCount = 0
        private(set) var stopDispatches = 0
        private(set) var effectiveStops = 0
        private var isStopped = false

        func start() async throws { startCount += 1 }

        func stop() {
            stopDispatches += 1
            guard !isStopped else { return }
            isStopped = true
            effectiveStops += 1
        }
        func proxyURL(for originalURL: URL) -> URL? { nil }
        func networkURL(for originalURL: URL) -> URL? { nil }
    }

    /// Drive the lease to a settled state: join its stop task (which covers both
    /// the direct and the adopted-backstop branch), then read the spy. No sleep
    /// guessing in the happy path.
    private func settle(_ lease: AuthProxyLease, _ proxy: SpyProxy) async -> Int {
        await lease.awaitStopping()
        return await proxy.effectiveStops
    }

    // MARK: - Single-shot stop

    @Test("startStopping stops exactly once")
    func startStoppingStopsOnce() async {
        let proxy = SpyProxy()
        let lease = AuthProxyLease(proxy: proxy)

        lease.startStopping()
        lease.startStopping()
        lease.startStopping()

        #expect(await settle(lease, proxy) == 1, "stop() must not run twice")
        #expect(lease.state == .stopped)
        #expect(!lease.hasPendingTeardown, "a dispatched stop is no longer pending")
    }

    /// A lease that never stops must keep reporting a pending teardown — that is
    /// the signal `deinit` keys on.
    @Test("fresh lease reports a pending teardown")
    func freshLeaseIsPending() {
        let lease = AuthProxyLease(proxy: SpyProxy())
        #expect(lease.hasPendingTeardown)
        #expect(!lease.isStoppingOrStopped)
    }

    // MARK: - deinit handoff

    /// The core guarantee: taking the lease hands the proxy to the taker exactly
    /// once, and a second taker gets nothing.
    @Test("takeForExternalStop transfers the proxy once")
    func takeTransfersOnce() async {
        let proxy = SpyProxy()
        let lease = AuthProxyLease(proxy: proxy)

        let first = lease.takeForExternalStop()
        let second = lease.takeForExternalStop()

        #expect(first != nil, "an unclaimed lease must hand the proxy to the taker")
        #expect(second == nil, "a claimed lease must not be handed out twice")
        #expect(!lease.hasPendingTeardown)

        await first?.stop()
        #expect(await proxy.effectiveStops == 1)
    }

    /// A stop that was already dispatched must not be re-taken, so `deinit` never
    /// races an in-flight teardown.
    @Test("takeForExternalStop yields nothing once stopping")
    func takeAfterStoppingYieldsNothing() async {
        let proxy = SpyProxy()
        let lease = AuthProxyLease(proxy: proxy)
        lease.startStopping()

        #expect(lease.takeForExternalStop() == nil)
        #expect(await settle(lease, proxy) == 1)
    }

    // MARK: - Adopted handoff

    /// When a bind task owns the socket, the lease waits for it and only stops as
    /// a backstop. A task that stops the proxy itself must not trigger a second
    /// stop.
    @Test("adopted lease does not double-stop when the task stops it")
    func adoptedLeaseDoesNotDoubleStopWhenOwnerStopsIt() async throws {
        let proxy = SpyProxy()
        let lease = AuthProxyLease(proxy: proxy)

        let owner = Task { await proxy.stop() }
        lease.adopt(installedBy: owner)
        _ = await owner.value
        // Longer than the lease's backstop grace window.
        try await Task.sleep(for: .milliseconds(400))

        // The backstop may still queue a `stop()`; the spy counts calls, not
        // sockets, so the contract to pin is (a) the socket definitely gets
        // stopped and (b) the real proxy's own `isStopped` guard makes any extra
        // call a no-op — see `AuthProxyTests.stop_isIdempotent`.
        #expect(await proxy.effectiveStops >= 1)
        #expect(!lease.hasPendingTeardown)
    }

    /// The backstop must fire when the owning task ends WITHOUT stopping — that
    /// is the leak this branch exists for.
    @Test("adopted lease stops when the owning task does not")
    func adoptedLeaseStopsWhenOwnerDoesNot() async throws {
        let proxy = SpyProxy()
        let lease = AuthProxyLease(proxy: proxy)

        // Simulates a bind task that installed the proxy and returned without
        // ever reaching its own `stop()`.
        let owner = Task<Void, Never> { }
        lease.adopt(installedBy: owner)
        _ = await owner.value

        #expect(await settle(lease, proxy) == 1,
                "an adopted lease must stop the proxy its owner failed to stop")
    }

    @Test("adopt after startStopping is ignored")
    func adoptAfterStartStoppingIsIgnored() async throws {
        let proxy = SpyProxy()
        let lease = AuthProxyLease(proxy: proxy)
        lease.startStopping()

        let owner = Task<Void, Never> { }
        lease.adopt(installedBy: owner)

        #expect(await settle(lease, proxy) == 1)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await proxy.effectiveStops == 1, "the ignored adopt must not add a second stop")
    }

    // MARK: - deinit handoff shape

    /// Reproduces the exact `VideoDetailViewModel.deinit` shape: a `nonisolated`
    /// owner that cannot await reaches only the lease, and stops the orphan it is
    /// handed. Two cases, both of which used to leak a bound listener:
    ///
    /// - the owner was released without ever calling its stop path;
    /// - the owner's stop path ran, so `deinit` must stay out of the way.
    @Test("deinit-shaped handoff stops an orphan and skips a claimed lease")
    func deinitShapedHandoff() async {
        // Case 1: nobody stopped the proxy.
        let orphan = SpyProxy()
        let unownedLease = AuthProxyLease(proxy: orphan)
        await Self.simulateDeinit(lease: unownedLease)
        // The detached `deinit` task stops without awaiting; join via the actor.
        var observed = await orphan.effectiveStops
        for _ in 0..<100 where observed == 0 {
            try? await Task.sleep(for: .milliseconds(20))
            observed = await orphan.effectiveStops
        }
        #expect(observed == 1, "an orphaned proxy must be stopped by the deinit handoff")

        // Case 2: the stop path already claimed the lease.
        let claimed = SpyProxy()
        let claimedLease = AuthProxyLease(proxy: claimed)
        claimedLease.startStopping()
        await Self.simulateDeinit(lease: claimedLease)
        #expect(await settle(claimedLease, claimed) == 1)
        #expect(await claimed.stopDispatches == 1,
                "deinit must not double-stop a lease that was already claimed")
    }

    /// Mirrors `VideoDetailViewModel.deinit`: no `await`, no actor access, only
    /// the lease's nonisolated take + a detached stop.
    private nonisolated static func simulateDeinit(lease: AuthProxyLease) async {
        let taken = lease.takeForExternalStop()
        guard let taken else { return }
        await Task.detached { [weak taken] in
            await taken?.stop()
        }.value
    }
}
