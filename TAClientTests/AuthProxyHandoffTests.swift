import Testing
import Foundation
@testable import TAClient

/// A stand-in for `AuthProxy` whose bind is slow and observable, so the
/// ViewModel's proxy handoff state machine can be driven without a real
/// `NWListener`.
///
/// The point of the fake is not the URL rewriting — `AuthProxyTests` covers that
/// against the real listener — but the *timing*: every leak fixed in
/// `startAuthProxy` / `cancelProxyStart` / `stopAuthProxy` is a bug about who
/// owns a socket across a suspension point, and only a bind that can be held
/// open and released on demand makes those interleavings reproducible.
actor FakeAuthProxy: AuthProxyConsumeProtocol {
    /// Seconds the fake spends "binding" before `start()` returns.
    private let bindDelay: Duration
    /// When set, `start()` throws after `bindDelay` instead of succeeding.
    private let failure: Error?

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var isRunning = false

    init(bindDelay: Duration = .milliseconds(120), failure: Error? = nil) {
        self.bindDelay = bindDelay
        self.failure = failure
    }

    func start() async throws {
        startCount += 1
        try await Task.sleep(for: bindDelay)
        if let failure { throw failure }
        isRunning = true
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }

    func proxyURL(for originalURL: URL) -> URL? {
        isRunning ? URL(string: "http://127.0.0.1:1\(originalURL.path)") : nil
    }

    func networkURL(for originalURL: URL) -> URL? {
        isRunning ? URL(string: "http://10.0.0.2:1\(originalURL.path)") : nil
    }
}

/// Proxy whose bind hangs until `releaseBind()` is called (or the awaiting task
/// is cancelled), giving the test exact control over "mid-bind".
actor HangingBindProxy: AuthProxyConsumeProtocol {
    private let gate = SendableBox<Bool>(false)
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var isRunning = false

    func start() async throws {
        startCount += 1
        var waited = 0
        while !gate.current {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
            waited += 10
            if waited > 5_000 { throw CancellationError() }
        }
        isRunning = true
    }

    func releaseBind() {
        gate.set(true)
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }

    func proxyURL(for originalURL: URL) -> URL? { nil }
    func networkURL(for originalURL: URL) -> URL? { nil }
}

/// Regression cover for the proxy handoff in `VideoDetailViewModel`.
///
/// Before the fix, `proxiedURL(for:token:forAirPlay:)` decided ownership with
/// `if let existing = authProxy { await newProxy.stop() }` after an `await`, and
/// `startDirectAVPlayback`'s abandon branch called `stopAuthProxy()`. Both were
/// written when VLC was the only proxy consumer; `2affeb2` added AVPlayer's
/// direct fallback and the AirPlay swap, so two callers can now race, and the
/// losing side either stopped a proxy that was in use or left a bound listener
/// holding the user's token with nobody assigned to stop it.
///
/// `.serialized` for the same reason as `AuthProxyLeaseTests`: the assertions are
/// on start/stop counts of proxies that other tests in the same process create and
/// tear down, and those dispatches are not ordered across tests.
@Suite(.serialized)
struct AuthProxyHandoffTests {

    // MARK: - Helpers

    /// A VM with credentials in `AuthState` but no video loaded, so nothing here
    /// touches AVPlayer or the preloader.
    private func makeViewModel() -> VideoDetailViewModel {
        let authState = MockResponse.makeAuthState()
        return VideoDetailViewModel(
            videoId: "vid1",
            videoRepository: MockVideoRepository(),
            authState: authState,
            router: AppRouter(authState: authState)
        )
    }

    /// Start a bind in a separate task so the test can act while it is suspended.
    /// `nil`-typed so "installed" and "abandoned" are distinguishable, which is
    /// what the assertions below key on.
    private func startInBackground(
        _ vm: VideoDetailViewModel,
        _ proxy: any AuthProxyConsumeProtocol
    ) -> Task<(any AuthProxyConsumeProtocol)?, Never> {
        Task { await vm.startAuthProxyForTests(proxy) }
    }

    // MARK: - Abandon while binding

    /// A bind that completes after the caller abandoned it must stop the proxy
    /// it created and install nothing.
    @Test("abandoned bind stops its own proxy and installs nothing")
    func abandonedBindStopsItsOwnProxy() async throws {
        let vm = makeViewModel()
        let proxy = HangingBindProxy()
        let started = startInBackground(vm, proxy)

        // Let the fake enter `start()` and park on the gate.
        try await Task.sleep(for: .milliseconds(80))
        #expect(await proxy.startCount == 1)
        #expect(vm.installedProxyForTests == nil, "nothing may be installed before the bind resolves")
        #expect(vm.pendingProxyStartForTests, "the handoff must be tracked while binding")

        vm.cancelProxyStartForTests()
        await proxy.releaseBind()

        #expect(await started.value == nil, "an abandoned start must report failure")
        // Give the task's `await proxy.stop()` a chance to land on the actor.
        try await Task.sleep(for: .milliseconds(150))
        #expect(await proxy.stopCount == 1, "the abandoning task must stop the socket it created")
        #expect(vm.installedProxyForTests == nil, "an abandoned bind must not install a proxy")
    }

    /// `stopPlayback()`'s teardown path (`stopAuthProxy`) must also reclaim a
    /// bind that finishes after the teardown, rather than leaving it bound.
    @Test("stop during bind reclaims the late proxy")
    func stopDuringBindReclaimsLateProxy() async throws {
        let vm = makeViewModel()
        let proxy = HangingBindProxy()
        let started = startInBackground(vm, proxy)

        try await Task.sleep(for: .milliseconds(80))
        await vm.stopAuthProxyAwaitingForTests()
        await proxy.releaseBind()

        let installed = await started.value
        try await Task.sleep(for: .milliseconds(150))
        let stopCount = await proxy.stopCount

        // Exactly one owner, whichever side won the race: the bind self-stopped
        // (installed == nil) or the teardown stopped what it installed. Either
        // way the socket does not outlive the teardown.
        #expect(installed == nil, "teardown must leave no installed proxy")
        #expect(stopCount == 1, "exactly one owner must stop the socket (stopCount=\(stopCount))")
    }

    // MARK: - Failure path

    /// A bind that throws must not leave the proxy installed and must release
    /// whatever the fake may have opened.
    @Test("failed bind installs nothing and releases the proxy")
    func failedBindReleasesProxy() async throws {
        let vm = makeViewModel()
        let proxy = FakeAuthProxy(bindDelay: .milliseconds(30), failure: URLError(.cannotConnectToHost))
        let installed = await vm.startAuthProxyForTests(proxy)

        #expect(installed == nil)
        #expect(vm.installedProxyForTests == nil)
        #expect(await proxy.stopCount == 1, "a failed bind must still stop the proxy it built")
        #expect(!vm.pendingProxyStartForTests, "the handoff slot must be cleared on failure")
    }

    // MARK: - Success path

    @Test("successful bind installs the proxy and is reused, not rebound")
    func successfulBindInstallsOnce() async throws {
        let vm = makeViewModel()
        let first = FakeAuthProxy(bindDelay: .milliseconds(20))
        let second = FakeAuthProxy(bindDelay: .milliseconds(20))

        #expect(await vm.startAuthProxyForTests(first) != nil)
        #expect(vm.installedProxyForTests === first)

        // A caller that arrives while a proxy is installed must reuse it: the
        // pre-fix code could bind a second listener and throw one away.
        #expect(await vm.startAuthProxyForTests(second) != nil)
        #expect(await second.startCount == 0, "an installed proxy must be reused, not rebound")
        #expect(vm.installedProxyForTests === first)

        await vm.stopAuthProxyAwaitingForTests()
        // `settle` joins the lease's own stop task, so there is no window where
        // the state is still `.stopping`: the actor finishes `stop()` before the
        // lease marks itself stopped.
        #expect(await first.stopCount == 1)
        #expect(vm.installedProxyForTests == nil)
        #expect(vm.proxyLeaseForTests?.state == .stopped,
                "the ViewModel path must drive the lease to a terminal state")
    }

    // MARK: - Superseded handoff

    /// A handoff that is still binding while a newer one takes the slot must
    /// stop its own socket and must not clobber the successor's state.
    @Test("superseded bind stops itself and leaves the successor installed")
    func supersededBindDoesNotClobberSuccessor() async throws {
        let vm = makeViewModel()
        let superseded = HangingBindProxy()
        let loser = startInBackground(vm, superseded)

        try await Task.sleep(for: .milliseconds(80))
        // Abandon the first handoff, then start a second one that will win.
        vm.cancelProxyStartForTests()
        let winner = FakeAuthProxy(bindDelay: .milliseconds(5))
        #expect(await vm.startAuthProxyForTests(winner) != nil)
        #expect(vm.installedProxyForTests === winner)

        await superseded.releaseBind()
        #expect(await loser.value == nil, "a superseded handoff must report failure")
        try await Task.sleep(for: .milliseconds(150))
        #expect(await superseded.stopCount == 1, "the superseded bind must stop its own socket")
        #expect(vm.installedProxyForTests === winner, "the successor must stay installed")
        #expect(await winner.stopCount == 0, "a superseded handoff must not stop the successor")

        await vm.stopAuthProxyAwaitingForTests()
        #expect(await winner.stopCount == 1)
    }

    // MARK: - Factory seam

    /// The handoff must build through `proxyFactory`, never through a hardcoded
    /// `AuthProxy(...)`: that seam is what keeps this whole ownership state
    /// machine testable, and a regression here silently un-testable the suite.
    @Test("handoff builds the proxy through proxyFactory")
    func handoffUsesProxyFactory() async throws {
        let vm = makeViewModel()
        let fake = FakeAuthProxy(bindDelay: .milliseconds(5))
        let built = SendableBox<[(token: String, host: String)]>([])
        vm.proxyFactory = { token, baseURL in
            var current = built.current
            current.append((token, baseURL.host ?? ""))
            built.set(current)
            return fake
        }

        #expect(await vm.startAuthProxyForTests(vm.proxyFactory("tok", URL(string: "https://ta.example.com")!)) != nil)
        #expect(built.current.map(\.token) == ["tok"])
        #expect(built.current.map(\.host) == ["ta.example.com"])
        #expect(vm.installedProxyForTests === fake)

        await vm.stopAuthProxyAwaitingForTests()
        #expect(await fake.stopCount == 1)
    }
}
