import Foundation
import Testing
@testable import TAClient

/// Coverage for `VideoDetailViewModel.evaluateReseedDispatch(...)`, the
/// testable seam wired into the 1Hz time observer's closure in Task 6 of
/// `docs/plans/20260526-fix-preloader-follow-large-scrub.md`.
///
/// **What this file does and doesn't cover:** these tests pin the evaluator's
/// pure decision logic — when should a reseed fire, when must it be debounced,
/// when must the nil-guard short-circuit, and what side effects (lock-guarded
/// scalar updates) happen on each path. They deliberately do NOT verify that
/// `VideoCachePreloader.shared.reseedMain` is actually called: the time
/// observer closure performs `Task { await reseedMain(...) }` based on this
/// method's return value, and `VideoCachePreloaderTests` already covers the
/// preloader-side behavior end-to-end. Splitting the responsibility this way
/// keeps each test focused and avoids needing to mock the preloader singleton.
///
/// **Why this is in `DataLayerSuite`:** the evaluator reads from
/// `VideoCachePreloader.shared.store` — a process-wide singleton. Parallel
/// tests would race on its `.main` region state. Same reasoning as
/// `VideoCachePreloaderTests`.
extension DataLayerSuite {
@MainActor
@Suite(.serialized) struct ReseedDispatchEvaluationTests {

    // No `init()` — each test calls `seedMainRegion` (which invokes the
    // store's synchronous `clear()` first) or `store.clear()` directly to
    // guarantee a known baseline. A `Task { await preloader.clear() }` in
    // init would race the test body, so we avoid it.

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

    /// Read `lastReseedAt` — written from inside the evaluator under
    /// `progressStateLock`. Mirror exposes `nonisolated(unsafe) private var`
    /// storage by label.
    private func readLastReseedAt(_ vm: VideoDetailViewModel) -> CFAbsoluteTime? {
        for child in Mirror(reflecting: vm).children where child.label == "lastReseedAt" {
            return child.value as? CFAbsoluteTime
        }
        return nil
    }

    private func readLastReseedTargetByte(_ vm: VideoDetailViewModel) -> Int64? {
        for child in Mirror(reflecting: vm).children where child.label == "lastReseedTargetByte" {
            return child.value as? Int64
        }
        return nil
    }

    // MARK: - Store seeding helper

    /// Seed `VideoCachePreloader.shared.store` with a synthetic `.main` region
    /// at `[mainStart..mainEnd)` for `videoId`. Uses `setEntry` (which creates
    /// `.main` anchored at `resumeByte`) and `writeChunk(.main, ...)` to push
    /// the region's `endOffset` to the target. `setEntry`'s prefix-region
    /// floor (8 MB) is not relevant — we choose `mainStart >= 8 MB` in tests
    /// so the prefix carve-out doesn't bump our anchor.
    private func seedMainRegion(
        videoId: String,
        mainStart: Int64,
        mainEnd: Int64,
        totalSize: Int64
    ) {
        let store = VideoCachePreloader.shared.store
        store.clear()
        store.setEntry(
            videoId: videoId,
            totalSize: totalSize,
            contentType: "video/mp4",
            resumeByte: mainStart
        )
        let bytesToWrite = Int(mainEnd - mainStart)
        if bytesToWrite > 0 {
            // One synthetic chunk is enough; the store doesn't care about
            // chunk size for region offset bookkeeping. The chunk's bytes
            // contribute to `endOffset` via the per-region append.
            _ = store.writeChunk(
                videoId: videoId,
                toRegion: .main,
                chunk: Data(repeating: 0xAA, count: bytesToWrite)
            )
        }
    }

    /// Wipe any seeded state from `VideoCachePreloader.shared.store`. Called
    /// at end of every test to avoid leakage into the next one (the
    /// `init` clears as well, but `clear()` is async so a synchronous flush
    /// here keeps state pin-clean during the test body).
    private func wipeStore() {
        VideoCachePreloader.shared.store.clear()
    }

    // MARK: - Tests

    /// **Integration / debounce test (plan line 299).**
    ///
    /// Given a VM with `.main` seeded at [100MB..200MB] and totalSize=1GB,
    /// when the evaluator is called 3 times within 1s at a position byte-mapped
    /// far past main (~500MB), then ONLY the first call returns a
    /// `ReseedDispatch`; the next two are debounce-suppressed because they
    /// target a similar byte within the 2s window. The plan's "single reseed
    /// despite 3 ticks" contract.
    @Test func debounce_threeRapidTicks_dispatchesOnce() {
        let vid = "vid-debounce"
        let totalSize: Int64 = 1_000_000_000
        let duration: Double = 1000
        seedMainRegion(videoId: vid, mainStart: 100_000_000, mainEnd: 200_000_000, totalSize: totalSize)
        defer { wipeStore() }

        let vm = makeSUT(videoId: vid)
        let url = URL(string: "https://ta.example.com/media/\(vid).mp4")!
        vm.snapshotPlaybackContext(url: url, token: "tok-1")

        // Position 500s -> 500MB byte (avgByterate = 1MB/s).
        // 500s is far past endSec=200s + 30s guard => triggers `shouldReseed`.
        let baseNow = CFAbsoluteTimeGetCurrent()

        let first = vm.evaluateReseedDispatch(
            currentSeconds: 500.0,
            cachedVideoId: vid,
            duration: duration,
            now: baseNow
        )
        let second = vm.evaluateReseedDispatch(
            currentSeconds: 500.5,
            cachedVideoId: vid,
            duration: duration,
            now: baseNow + 0.3
        )
        let third = vm.evaluateReseedDispatch(
            currentSeconds: 501.0,
            cachedVideoId: vid,
            duration: duration,
            now: baseNow + 0.9
        )

        #expect(first != nil, "First tick should dispatch — main is at [100..200], pos=500s is far outside guard band")
        #expect(second == nil, "Second tick (0.3s later, byte within 10MB) should be debounce-suppressed")
        #expect(third == nil, "Third tick (0.9s later, byte within 10MB) should be debounce-suppressed")
        #expect(first?.atByte == 500_000_000)
        #expect(first?.url == url)
        #expect(first?.token == "tok-1")

        // Side-effect verification: the first call's `now` is what got
        // recorded in `lastReseedAt`. The second/third calls did NOT advance
        // it (since they were debounced).
        #expect(readLastReseedAt(vm) == baseNow, "lastReseedAt should reflect ONLY the first (un-debounced) call's now")
        #expect(readLastReseedTargetByte(vm) == 500_000_000)
    }

    /// After the debounce window expires (>2s), a follow-up tick at a similar
    /// byte target dispatches again. Pins the "stale 2s debounce is harmless"
    /// contract from the plan (CLAUDE.md note in `lastReseedAt`).
    @Test func debounce_afterWindow_dispatchesAgain() {
        let vid = "vid-debounce-window"
        let totalSize: Int64 = 1_000_000_000
        let duration: Double = 1000
        seedMainRegion(videoId: vid, mainStart: 100_000_000, mainEnd: 200_000_000, totalSize: totalSize)
        defer { wipeStore() }

        let vm = makeSUT(videoId: vid)
        vm.snapshotPlaybackContext(url: URL(string: "https://ta.example.com/x.mp4")!, token: "tok")

        let baseNow = CFAbsoluteTimeGetCurrent()
        let first = vm.evaluateReseedDispatch(
            currentSeconds: 500.0, cachedVideoId: vid, duration: duration, now: baseNow
        )
        let second = vm.evaluateReseedDispatch(
            currentSeconds: 500.0, cachedVideoId: vid, duration: duration, now: baseNow + 2.5
        )
        #expect(first != nil)
        #expect(second != nil, "After 2.5s (> 2s debounce), the same target should fire again")
    }

    /// **URL/token nil-guard test (plan line 300).**
    ///
    /// If `streamingURL` is nil (`configureAsset` never ran, or `stopPlayback`
    /// cleared it), the evaluator must return nil — i.e. no `reseedMain`
    /// dispatch downstream. This is the "no auth context, no dispatch"
    /// short-circuit.
    @Test func nilURL_returnsNil() {
        let vid = "vid-nil-url"
        let totalSize: Int64 = 1_000_000_000
        seedMainRegion(videoId: vid, mainStart: 100_000_000, mainEnd: 200_000_000, totalSize: totalSize)
        defer { wipeStore() }

        let vm = makeSUT(videoId: vid)
        // Token-only snapshot: nil URL, non-nil token.
        vm.snapshotPlaybackContext(url: nil, token: "tok-only")

        let result = vm.evaluateReseedDispatch(
            currentSeconds: 500.0, cachedVideoId: vid, duration: 1000, now: CFAbsoluteTimeGetCurrent()
        )
        #expect(result == nil, "Nil URL must short-circuit dispatch")
        // Pair-check inside the lock: timestamps must NOT advance when the
        // pair is incomplete — otherwise a follow-up valid tick within 2s
        // would be debounce-suppressed. Iter 2 moved the pair-check inside
        // the lock specifically to guarantee this; this assertion locks it
        // down.
        #expect(readLastReseedAt(vm) == 0, "lastReseedAt must stay at init-time 0 when URL is nil")
        #expect(readLastReseedTargetByte(vm) == 0, "lastReseedTargetByte must stay at init-time 0 when URL is nil")
    }

    /// Same shape as above but for nil token. The pair-check fails — return nil.
    @Test func nilToken_returnsNil() {
        let vid = "vid-nil-token"
        let totalSize: Int64 = 1_000_000_000
        seedMainRegion(videoId: vid, mainStart: 100_000_000, mainEnd: 200_000_000, totalSize: totalSize)
        defer { wipeStore() }

        let vm = makeSUT(videoId: vid)
        vm.snapshotPlaybackContext(url: URL(string: "https://ta.example.com/x.mp4")!, token: nil)

        let result = vm.evaluateReseedDispatch(
            currentSeconds: 500.0, cachedVideoId: vid, duration: 1000, now: CFAbsoluteTimeGetCurrent()
        )
        #expect(result == nil, "Nil token must short-circuit dispatch")
        #expect(readLastReseedAt(vm) == 0, "lastReseedAt must stay at init-time 0 when token is nil")
        #expect(readLastReseedTargetByte(vm) == 0, "lastReseedTargetByte must stay at init-time 0 when token is nil")
    }

    /// Both URL AND token nil — fresh VM, never configured. The earliest
    /// short-circuit possible. Pairs with `stopPlayback`'s clear path.
    @Test func bothNil_returnsNil() {
        let vid = "vid-both-nil"
        let totalSize: Int64 = 1_000_000_000
        seedMainRegion(videoId: vid, mainStart: 100_000_000, mainEnd: 200_000_000, totalSize: totalSize)
        defer { wipeStore() }

        let vm = makeSUT(videoId: vid)
        // No snapshotPlaybackContext call — fields stay nil from init.

        let result = vm.evaluateReseedDispatch(
            currentSeconds: 500.0, cachedVideoId: vid, duration: 1000, now: CFAbsoluteTimeGetCurrent()
        )
        #expect(result == nil)
        #expect(readLastReseedAt(vm) == 0, "lastReseedAt must stay at init-time 0 when both URL+token are nil")
        #expect(readLastReseedTargetByte(vm) == 0, "lastReseedTargetByte must stay at init-time 0 when both URL+token are nil")
    }

    /// **Advance-then-nil-then-resnapshot test (iter 3 / Testing #4).**
    ///
    /// After one successful dispatch advances `lastReseedAt`/
    /// `lastReseedTargetByte`, a subsequent `snapshotPlaybackContext(nil,
    /// nil)` (simulating `stopPlayback` clearing the snapshot) followed by
    /// another evaluator call MUST NOT advance the timestamps further. The
    /// pair-guard inside the lock returns nil before touching the scalars,
    /// preserving the previously-recorded values.
    @Test func nilPair_afterDispatch_preservesTimestamps() {
        let vid = "vid-nil-preserve"
        let totalSize: Int64 = 1_000_000_000
        seedMainRegion(videoId: vid, mainStart: 100_000_000, mainEnd: 200_000_000, totalSize: totalSize)
        defer { wipeStore() }

        let vm = makeSUT(videoId: vid)
        vm.snapshotPlaybackContext(
            url: URL(string: "https://ta.example.com/x.mp4")!,
            token: "tok"
        )

        let baseNow = CFAbsoluteTimeGetCurrent()
        let first = vm.evaluateReseedDispatch(
            currentSeconds: 500.0, cachedVideoId: vid, duration: 1000, now: baseNow
        )
        #expect(first != nil)
        let snappedAt = readLastReseedAt(vm)
        let snappedByte = readLastReseedTargetByte(vm)
        #expect(snappedAt == baseNow)
        #expect(snappedByte == 500_000_000)

        // Clear the pair (simulates stopPlayback's progressStateLock-guarded
        // clear of streamingURL/authToken).
        vm.snapshotPlaybackContext(url: nil, token: nil)

        // Another tick lands well outside the debounce window so the
        // debounce check would not suppress — but the nil-pair guard MUST.
        let second = vm.evaluateReseedDispatch(
            currentSeconds: 700.0,
            cachedVideoId: vid,
            duration: 1000,
            now: baseNow + 10  // far outside the 2s debounce window
        )
        #expect(second == nil, "Nil pair after previous dispatch must short-circuit")
        // Timestamps preserved at the previous successful-dispatch values
        // — NOT advanced to the failed tick's `baseNow + 10` / `700_000_000`.
        #expect(readLastReseedAt(vm) == snappedAt,
                "lastReseedAt must remain at the previous successful dispatch's value")
        #expect(readLastReseedTargetByte(vm) == snappedByte,
                "lastReseedTargetByte must remain at the previous successful dispatch's value")
    }

    /// **Direct-asset bypass test (iter 3 / Quality #7 / Testing #3).**
    ///
    /// When `isUsingDirectAsset == true`, the evaluator MUST return nil and
    /// NOT touch debounce scalars — AVPlayer is reading straight from the
    /// server (AirPlay, AirPlay-swap, or cachingURL-conversion-failure
    /// fallback), so any reseed dispatch would download bytes the player
    /// never reads. This is the "Step 0" early-bail in
    /// `evaluateReseedDispatch`. Without this test, a regression that
    /// removes the bypass guard would silently waste bandwidth in production.
    @Test func evaluator_directAssetBypass_returnsNil() {
        let vid = "vid-direct-asset"
        let totalSize: Int64 = 1_000_000_000
        let duration: Double = 1000
        seedMainRegion(videoId: vid, mainStart: 100_000_000, mainEnd: 200_000_000, totalSize: totalSize)
        defer { wipeStore() }

        let vm = makeSUT(videoId: vid)
        // Set up valid URL+token AND seed mainRegion that would otherwise
        // trigger reseed (position 500s -> 500MB byte, outside main).
        vm.snapshotPlaybackContext(
            url: URL(string: "https://ta.example.com/direct.mp4")!,
            token: "tok-direct"
        )
        // Flip the direct-asset bit using the internal test-only setter.
        vm.setDirectAssetState(true)

        let baseNow = CFAbsoluteTimeGetCurrent()
        let result = vm.evaluateReseedDispatch(
            currentSeconds: 500.0,
            cachedVideoId: vid,
            duration: duration,
            now: baseNow
        )
        #expect(result == nil, "Direct-asset bypass must short-circuit dispatch even when shouldReseed would fire")

        // Side-effect check: debounce scalars must NOT have advanced — Step 0
        // bails BEFORE the locked debounce-and-snapshot block.
        let baselineReseedAt = readLastReseedAt(vm) ?? -1
        #expect(baselineReseedAt == 0,
                "Direct-asset bypass must NOT advance lastReseedAt (stays at init-time 0)")
        let baselineTargetByte = readLastReseedTargetByte(vm) ?? -1
        #expect(baselineTargetByte == 0,
                "Direct-asset bypass must NOT advance lastReseedTargetByte (stays at init-time 0)")

        // Flip back to caching-loader mode → next tick should dispatch.
        vm.setDirectAssetState(false)
        let resultAfterFlip = vm.evaluateReseedDispatch(
            currentSeconds: 500.0,
            cachedVideoId: vid,
            duration: duration,
            now: baseNow
        )
        #expect(resultAfterFlip != nil,
                "After clearing the direct-asset bit, the same tick MUST dispatch — pinning Step 0 as the sole bypass")
    }

    /// **Paused-player scrub structural test (plan line 301).**
    ///
    /// The evaluator's API surface does not include AVPlayer state —
    /// parameters are `(currentSeconds, cachedVideoId, duration, now)` and
    /// nothing else. This test confirms dispatch fires from position alone
    /// (no AVPlayer attached to the SUT), pinning the "paused does NOT
    /// block reseed" structural contract: if a future refactor adds a
    /// `rate > 0` guard either via a new parameter or via internal state,
    /// this test fails immediately. It deliberately does NOT simulate a
    /// real paused-AVPlayer scenario — the absence of the check is
    /// guaranteed by the API shape, not by behavioral observation.
    @Test func evaluatorFiresOnPositionAlone() {
        let vid = "vid-paused-scrub"
        let totalSize: Int64 = 1_000_000_000
        seedMainRegion(videoId: vid, mainStart: 100_000_000, mainEnd: 200_000_000, totalSize: totalSize)
        defer { wipeStore() }

        let vm = makeSUT(videoId: vid)
        // VM has no AVPlayer attached — so `timeControlStatus` is moot.
        // The evaluator runs purely on its inputs. The dispatch should fire.
        vm.snapshotPlaybackContext(
            url: URL(string: "https://ta.example.com/paused.mp4")!,
            token: "paused-tok"
        )

        let dispatch = vm.evaluateReseedDispatch(
            currentSeconds: 500.0,
            cachedVideoId: vid,
            duration: 1000,
            now: CFAbsoluteTimeGetCurrent()
        )
        #expect(dispatch != nil, "Paused-scrub tick must still dispatch — paused does NOT block reseed (pre-warm intent)")
        #expect(dispatch?.atByte == 500_000_000)
    }

    /// Sanity: position INSIDE main returns nil (no dispatch). Pins the
    /// trigger gate so a regression that drops `shouldReseed` and dispatches
    /// every tick fails this test.
    @Test func positionInsideMain_returnsNil() {
        let vid = "vid-inside-main"
        let totalSize: Int64 = 1_000_000_000
        seedMainRegion(videoId: vid, mainStart: 100_000_000, mainEnd: 200_000_000, totalSize: totalSize)
        defer { wipeStore() }

        let vm = makeSUT(videoId: vid)
        vm.snapshotPlaybackContext(url: URL(string: "https://ta.example.com/x.mp4")!, token: "tok")

        // 150s -> 150MB byte. Inside main [100..200]. shouldReseed => false.
        let result = vm.evaluateReseedDispatch(
            currentSeconds: 150.0, cachedVideoId: vid, duration: 1000, now: CFAbsoluteTimeGetCurrent()
        )
        #expect(result == nil)
    }

    /// Sanity: when there is no `.main` region in the store (no entry, or
    /// small-file case), the evaluator returns nil without touching debounce
    /// scalars. This is the "store says I have nothing for you" short-circuit.
    @Test func noMainRegion_returnsNil() {
        let vid = "vid-no-main"
        VideoCachePreloader.shared.store.clear()
        defer { wipeStore() }

        let vm = makeSUT(videoId: vid)
        vm.snapshotPlaybackContext(url: URL(string: "https://ta.example.com/x.mp4")!, token: "tok")

        let result = vm.evaluateReseedDispatch(
            currentSeconds: 500.0, cachedVideoId: vid, duration: 1000, now: CFAbsoluteTimeGetCurrent()
        )
        #expect(result == nil, "No region => no dispatch (preloader hasn't seeded yet)")
    }
}
}
