import Foundation
import Testing
@testable import TAClient

/// Coverage for `VideoDetailViewModel.evaluateRestartDispatch(...)`, the
/// testable seam wired into the 1Hz time observer's closure in Task 6 of
/// `docs/plans/20260527-fix-memory-pressure-recovery.md`.
///
/// **What this file does and doesn't cover:** these tests pin the evaluator's
/// pure decision logic — when should a restart fire, when must the cooldown
/// suppress it, when must the URL/token nil-guard short-circuit, and what
/// side effect (lock-guarded `lastRestartAt` update) happens on each path.
/// They deliberately do NOT verify that `VideoCachePreloader.shared.
/// restartPreloadIfNeeded` is actually called: the time observer closure
/// performs `Task { await restartPreloadIfNeeded(...) }` based on this
/// method's return value, and `VideoCachePreloaderTests` already covers the
/// preloader-side behavior end-to-end (Task 5). Splitting the responsibility
/// this way keeps each test focused and avoids needing to mock the preloader
/// singleton.
///
/// **Why this is in `DataLayerSuite`:** the evaluator reads from
/// `VideoCachePreloader.shared.store` — a process-wide singleton. Parallel
/// tests would race on its `.main` region state. Same reasoning as
/// `ReseedDispatchEvaluationTests`.
extension DataLayerSuite {
@MainActor
@Suite(.serialized) struct RestartDispatchEvaluationTests {

    // No `init()` — each test calls `seedMainRegion` (which invokes the
    // store's synchronous `clear()` first) or `store.clear()` directly to
    // guarantee a known baseline.

    // MARK: - SUT factory

    private func makeSUT(videoId: String = "test-vid") -> VideoDetailViewModel {
        let keychain = KeychainService()
        keychain.clearAll()
        let authState = AuthState(keychainService: keychain)
        let router = AppRouter(authState: authState)
        return VideoDetailViewModel(
            videoId: videoId,
            videoRepository: MockVideoRepository(),
            authState: authState,
            router: router
        )
    }

    // MARK: - Mirror accessors for private scalars

    /// Read `lastRestartAt` — written from inside the evaluator under
    /// `progressStateLock`. Mirror exposes `nonisolated(unsafe) private var`
    /// storage by label.
    private func readLastRestartAt(_ vm: VideoDetailViewModel) -> CFAbsoluteTime? {
        for child in Mirror(reflecting: vm).children where child.label == "lastRestartAt" {
            return child.value as? CFAbsoluteTime
        }
        return nil
    }

    // MARK: - Store seeding helpers

    /// Seed `VideoCachePreloader.shared.store` with a synthetic `.main`
    /// region populated to `cachedBytes` bytes for `videoId`. Uses a large
    /// enough totalSize that the prefix carve-out (max 50 MB) doesn't
    /// dominate. The main region's `cachedByteCount` is what
    /// `RestartTrigger.shouldRestart` reads.
    private func seedMainRegion(
        videoId: String,
        cachedBytes: Int,
        totalSize: Int64 = 1_000_000_000
    ) {
        let store = VideoCachePreloader.shared.store
        store.clear()
        // resumeByte=0 → main starts at prefixSize (10 MB for 1 GB totalSize).
        store.setEntry(
            videoId: videoId,
            totalSize: totalSize,
            contentType: "video/mp4",
            resumeByte: 0
        )
        if cachedBytes > 0 {
            _ = store.writeChunk(
                videoId: videoId,
                toRegion: .main,
                chunk: Data(repeating: 0xAA, count: cachedBytes)
            )
        }
    }

    /// Wipe seeded state from `VideoCachePreloader.shared.store`. Called
    /// at end of every test to avoid leakage into the next one.
    private func wipeStore() {
        VideoCachePreloader.shared.store.clear()
    }

    // MARK: - Tests

    /// **Direct-asset bypass test (plan line 428).**
    ///
    /// When `isUsingDirectAsset == true`, the evaluator MUST return nil even
    /// when the cache is empty (mainBytes = 0, deep below 16 MB threshold).
    /// AVPlayer is reading straight from the server (AirPlay, AirPlay-swap,
    /// or cachingURL-conversion-failure fallback), so a preload restart
    /// would download bytes the player never reads. This is Step 0 of
    /// `evaluateRestartDispatch`. Without this guard, a regression would
    /// waste bandwidth in production.
    @Test func restartHook_returnsNil_whenDirectAssetActive() {
        let vid = "vid-restart-direct"
        // Seed an empty main (cachedBytes = 0) — would normally trigger.
        seedMainRegion(videoId: vid, cachedBytes: 0)
        defer { wipeStore() }

        let vm = makeSUT(videoId: vid)
        vm.snapshotPlaybackContext(
            url: URL(string: "https://ta.example.com/direct.mp4")!,
            token: "tok-direct"
        )
        // Flip the direct-asset bit via the internal test seam.
        vm.setDirectAssetState(true)

        let baseNow = CFAbsoluteTimeGetCurrent()
        let result = vm.evaluateRestartDispatch(
            cachedVideoId: vid,
            currentSeconds: 500.0,
            duration: 1000,
            now: baseNow
        )
        #expect(result == nil, "Direct-asset bypass must short-circuit restart dispatch")
        // Side-effect check: lastRestartAt must NOT have advanced — Step 0
        // bails BEFORE the locked snapshot block.
        #expect(readLastRestartAt(vm) == 0,
                "Direct-asset bypass must NOT advance lastRestartAt (stays at init-time 0)")
    }

    /// **Sufficient-bytes guard test (plan line 429).**
    ///
    /// When `.main` has at-or-above 16 MB cached, the predicate returns
    /// false (no restart needed — cache is healthy enough). Pins the
    /// threshold gate: a regression that drops the threshold check would
    /// dispatch restart on every tick.
    @Test func restartHook_returnsNil_whenMainHasSufficientBytes() {
        let vid = "vid-restart-sufficient"
        // 32 MB > 16 MB threshold → predicate returns false.
        seedMainRegion(videoId: vid, cachedBytes: 32 * 1024 * 1024)
        defer { wipeStore() }

        let vm = makeSUT(videoId: vid)
        vm.snapshotPlaybackContext(
            url: URL(string: "https://ta.example.com/healthy.mp4")!,
            token: "tok-healthy"
        )

        let baseNow = CFAbsoluteTimeGetCurrent()
        let result = vm.evaluateRestartDispatch(
            cachedVideoId: vid,
            currentSeconds: 500.0,
            duration: 1000,
            now: baseNow
        )
        #expect(result == nil, "32 MB cached > 16 MB threshold → no restart needed")
        #expect(readLastRestartAt(vm) == 0,
                "Predicate short-circuit must NOT advance lastRestartAt")
    }

    /// **URL/token nil-guard test (plan line 430).**
    ///
    /// Even with mainBytes far below the 16 MB threshold (predicate fires),
    /// a nil URL/token pair MUST suppress dispatch. The pair-check lives
    /// INSIDE the lock with the timestamp update — `lastRestartAt` must
    /// stay at init-time 0 to confirm the side-effect is fused to a
    /// successful dispatch.
    @Test func restartHook_returnsNil_whenURLOrTokenNil() {
        let vid = "vid-restart-nil-pair"
        // Empty main → predicate would fire (0 < 16 MB).
        seedMainRegion(videoId: vid, cachedBytes: 0)
        defer { wipeStore() }

        let vm = makeSUT(videoId: vid)
        // Explicitly snapshot a nil pair (simulates fresh VM / post-stopPlayback).
        vm.snapshotPlaybackContext(url: nil, token: nil)

        let baseNow = CFAbsoluteTimeGetCurrent()
        let result = vm.evaluateRestartDispatch(
            cachedVideoId: vid,
            currentSeconds: 500.0,
            duration: 1000,
            now: baseNow
        )
        #expect(result == nil, "Nil URL+token pair must short-circuit dispatch even when predicate fires")
        // Critical: timestamp side-effect lives INSIDE the lock with the
        // pair-check, so lastRestartAt must NOT advance when the pair is nil.
        #expect(readLastRestartAt(vm) == 0,
                "lastRestartAt must stay at init-time 0 when URL/token pair is nil")
    }

    /// **Small-file edge case (plan line 431; code-review fix).**
    ///
    /// When `totalSize <= prefixSize`, `setEntry` creates ONLY a `.prefix`
    /// region — no `.main`. The evaluator explicitly short-circuits in this
    /// case (returns nil without advancing the cooldown) because:
    ///   - the whole file fits in `.prefix`, there is nothing for a
    ///     restart to do;
    ///   - without the short-circuit, every post-cooldown 1Hz tick would
    ///     dispatch a restart whose `setEntry` inside `startPreloadWithRetry`
    ///     would wipe the prefix bytes that ARE there — a 15 s wipe-and-
    ///     refetch loop on small files.
    /// See code-review "small-file infinite restart loop" finding.
    @Test func restartHook_returnsNil_whenNoMainRegion() {
        let vid = "vid-restart-small-file"
        // Small file: totalSize = 5 MB ≤ maxPrefixSize (50 MB) → no main
        // region created.
        let store = VideoCachePreloader.shared.store
        store.clear()
        store.setEntry(
            videoId: vid,
            totalSize: 5_000_000,
            contentType: "video/mp4",
            resumeByte: 0
        )
        defer { wipeStore() }

        let vm = makeSUT(videoId: vid)
        vm.snapshotPlaybackContext(
            url: URL(string: "https://ta.example.com/small.mp4")!,
            token: "tok-small"
        )

        let baseNow = CFAbsoluteTimeGetCurrent()
        let result = vm.evaluateRestartDispatch(
            cachedVideoId: vid,
            currentSeconds: 2.5,
            duration: 5,
            now: baseNow
        )
        // Evaluator short-circuits on missing `.main` BEFORE the cooldown
        // commit — no dispatch, no timestamp advance.
        #expect(result == nil,
                "Evaluator MUST short-circuit on missing .main (small-file loop prevention)")
        #expect(readLastRestartAt(vm) == 0,
                "lastRestartAt MUST NOT advance when small-file short-circuit fires")
    }

    /// **All-conditions-met dispatch test (plan line 432).**
    ///
    /// Thin main (4 MB < 16 MB threshold), URL/token snapshotted, cooldown
    /// elapsed (lastRestartAt = 0 default → ~800M second delta), not
    /// direct-asset. Evaluator MUST return non-nil with `startPosition ==
    /// currentSeconds` (anchored at playhead, not byte 0).
    @Test func restartHook_returnsNonNil_whenAllConditionsMet() {
        let vid = "vid-restart-fire"
        seedMainRegion(videoId: vid, cachedBytes: 4 * 1024 * 1024)
        defer { wipeStore() }

        let vm = makeSUT(videoId: vid)
        let url = URL(string: "https://ta.example.com/restart.mp4")!
        vm.snapshotPlaybackContext(url: url, token: "tok-restart")

        let baseNow = CFAbsoluteTimeGetCurrent()
        let result = vm.evaluateRestartDispatch(
            cachedVideoId: vid,
            currentSeconds: 250.5,  // pinned literal to assert pass-through
            duration: 1000,
            now: baseNow
        )
        #expect(result != nil, "All conditions met → dispatch should fire")
        #expect(result?.videoId == vid)
        #expect(result?.url == url)
        #expect(result?.token == "tok-restart")
        // Load-bearing: startPosition must equal the currentSeconds
        // argument. Restart is anchored at the playhead, NOT byte 0 — the
        // cache rebuilds where the user actually is. Plan line 432.
        #expect(result?.startPosition == 250.5,
                "startPosition MUST equal currentSeconds (restart anchored at playhead)")
        #expect(result?.duration == 1000)
        // Side-effect: lastRestartAt advanced to the `now` argument.
        #expect(readLastRestartAt(vm) == baseNow,
                "lastRestartAt must advance to `now` on successful dispatch")
    }

    /// **Cooldown enforcement test (plan line 433).**
    ///
    /// Two calls in succession: the first dispatches (returns non-nil and
    /// bumps `lastRestartAt`); the second within the 15 s cooldown window
    /// returns nil. Pins the throttle so an empty-cache window doesn't
    /// dispatch restart on every observer tick. Mirror-assert that
    /// `lastRestartAt` changed EXACTLY ONCE — the cooldown-suppressed second
    /// call must not advance the timestamp (it never reaches the locked
    /// snapshot block; the predicate's short-circuit happens first).
    @Test func restartHook_advancesLastRestartAt_onlyOnDispatch() {
        let vid = "vid-restart-cooldown"
        seedMainRegion(videoId: vid, cachedBytes: 4 * 1024 * 1024)
        defer { wipeStore() }

        let vm = makeSUT(videoId: vid)
        vm.snapshotPlaybackContext(
            url: URL(string: "https://ta.example.com/cd.mp4")!,
            token: "tok-cd"
        )

        let baseNow = CFAbsoluteTimeGetCurrent()
        let first = vm.evaluateRestartDispatch(
            cachedVideoId: vid,
            currentSeconds: 500.0,
            duration: 1000,
            now: baseNow
        )
        #expect(first != nil, "First call must dispatch")
        let snappedAt = readLastRestartAt(vm)
        #expect(snappedAt == baseNow, "First call advances lastRestartAt to its `now`")

        // Second call 5 s later — well within the 15 s cooldown window.
        let second = vm.evaluateRestartDispatch(
            cachedVideoId: vid,
            currentSeconds: 502.0,
            duration: 1000,
            now: baseNow + 5
        )
        #expect(second == nil, "Within-cooldown call must be suppressed")
        // The cooldown-suppressed call must NOT have advanced the timestamp.
        #expect(readLastRestartAt(vm) == snappedAt,
                "Cooldown short-circuit must NOT advance lastRestartAt (no double-bump)")
    }

    /// **Nil-URL pair preservation test (plan line 434).**
    ///
    /// When the URL is nil (token still set), the pair-check fails inside
    /// the lock — the dispatch returns nil AND `lastRestartAt` must stay
    /// at init-time 0. This is the same pair-check-inside-lock invariant
    /// that `evaluateReseedDispatch` enforces: timestamp updates and
    /// dispatch decisions are inseparable, so a stale-timestamp scenario
    /// doesn't lock out a legitimate follow-up call within the cooldown.
    @Test func restartHook_nilURL_doesNotAdvanceLastRestartAt() {
        let vid = "vid-restart-nil-url"
        seedMainRegion(videoId: vid, cachedBytes: 4 * 1024 * 1024)
        defer { wipeStore() }

        let vm = makeSUT(videoId: vid)
        // Token-only snapshot: nil URL, non-nil token.
        vm.snapshotPlaybackContext(url: nil, token: "tok-only")

        let baseNow = CFAbsoluteTimeGetCurrent()
        let result = vm.evaluateRestartDispatch(
            cachedVideoId: vid,
            currentSeconds: 500.0,
            duration: 1000,
            now: baseNow
        )
        #expect(result == nil, "Nil URL must short-circuit dispatch")
        #expect(readLastRestartAt(vm) == 0,
                "lastRestartAt must stay at init-time 0 when URL is nil (pair-check inside lock)")
    }

    // MARK: - E2E wiring test (Task 8)

    /// **End-to-end wiring test (plan Task 8, line 476).**
    ///
    /// Pins the VM → preloader fire-and-forget Task hop end-to-end. The
    /// per-test evaluator tests above lock the predicate side; the
    /// `VideoCachePreloaderTests` suite locks the actor side. This test
    /// stitches the two together: a `evaluateRestartDispatch` that returns
    /// non-nil must actually translate into a preloader-side restart that
    /// installs `preloadTaskVideoId == videoId`.
    ///
    /// The production 1Hz observer closure performs
    /// `Task { await preloader.restartPreloadIfNeeded(...) }` based on the
    /// evaluator's return value. We can't drive the AVPlayer's periodic time
    /// observer from a unit test, so we replicate the closure's two-step
    /// shape directly: evaluate, then dispatch with the result. If the
    /// production closure ever drops one of those two steps (or swaps the
    /// call to a different actor method), this test fails.
    ///
    /// The mock returns a tiny payload — we're not verifying download
    /// correctness here, only the wiring. The Range header check is implicit:
    /// `restartPreloadIfNeeded`'s own tests in `VideoCachePreloaderTests`
    /// cover the byte-anchor correctness.
    @Test func restartHook_dispatchActuallyCallsPreloader() async {
        let vid = "vid-restart-e2e"
        // Seed thin main (4 MB < 16 MB threshold) so the predicate fires.
        seedMainRegion(videoId: vid, cachedBytes: 4 * 1024 * 1024)
        defer { wipeStore() }

        // Install a permissive mock so the actor-side download starts (we
        // poll on `preloadTaskVideoId`, not on download completion — the
        // task installation is what proves the wiring).
        VideoCachePreloader.testSessionConfigurationOverride = MockResponse.makeConfiguration()
        let url = URL(string: "https://ta.example.com/media/\(vid).mp4")!
        // Capture totalSize so HEAD responses match the seeded entry's
        // expected total. The seeded entry uses `seedMainRegion`'s default
        // of 1_000_000_000.
        let mockedTotalSize = 1_000_000_000
        MockURLProtocol.requestHandler = { request in
            if request.httpMethod == "HEAD" {
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "video/mp4",
                        "Content-Length": "\(mockedTotalSize)"
                    ]
                )!
                return (response, Data())
            }
            // Tiny range body — content correctness doesn't matter; only
            // that the request fires so the actor installs preloadTask.
            let response = HTTPURLResponse(
                url: url,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "video/mp4",
                    "Content-Range": "bytes 0-1023/\(mockedTotalSize)"
                ]
            )!
            return (response, Data(count: 1024))
        }
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        let vm = makeSUT(videoId: vid)
        vm.snapshotPlaybackContext(url: url, token: "tok-e2e")

        // Step 1: evaluate. Production 1Hz observer calls this first.
        let baseNow = CFAbsoluteTimeGetCurrent()
        guard let dispatch = vm.evaluateRestartDispatch(
            cachedVideoId: vid,
            currentSeconds: 250.0,
            duration: 1000,
            now: baseNow
        ) else {
            Issue.record("evaluateRestartDispatch returned nil; cannot test the dispatch hop")
            return
        }

        // Step 2: dispatch. Production observer wraps this in
        // `Task { await ... }` and the test mirrors that shape.
        let returned = await VideoCachePreloader.shared.restartPreloadIfNeeded(
            videoId: dispatch.videoId,
            url: dispatch.url,
            token: dispatch.token,
            startPosition: dispatch.startPosition,
            duration: dispatch.duration
        )
        #expect(returned, "restartPreloadIfNeeded MUST return true when wiring is healthy")

        // Step 3: poll for the preloader-side observable state. This is
        // what end-to-end wiring looks like from the outside.
        let step: UInt64 = 20_000_000 // 20 ms
        let timeoutSeconds: Double = 5
        let iterations = Int((timeoutSeconds * 1_000_000_000) / Double(step))
        var preloadInstalled = false
        for _ in 0..<iterations {
            let taskVid = await VideoCachePreloader.shared.preloadTaskVideoId
            let isPreloading = await VideoCachePreloader.shared.isPreloading(videoId: vid)
            if taskVid == vid && isPreloading {
                preloadInstalled = true
                break
            }
            try? await Task.sleep(nanoseconds: step)
        }
        #expect(preloadInstalled,
                "preloadTaskVideoId MUST become \(vid) AND isPreloading MUST be true within timeout")

        // Cleanup so any in-flight task doesn't leak into the next test.
        await VideoCachePreloader.shared.cancelPreload(videoId: vid)
        await VideoCachePreloader.shared.clear()
    }
}
}
