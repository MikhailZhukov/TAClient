import Foundation
import Testing
@testable import TAClient

/// Side-bug coverage for the cosmetic init-time defaulting of
/// `VideoDetailViewModel.lastExplicitSeekAt`.
///
/// Background: the diagnostic `[TailReplay] BACKWARD_JUMP` line prints
/// `sinceLastSeek = CFAbsoluteTimeGetCurrent() - lastExplicitSeekAt`. Before
/// this fix, the field defaulted to `0` (CFAbsoluteTime epoch is 2001-01-01),
/// so on a freshly-loaded video that had `startPosition == 0` (no startup
/// seek to record) the very first jump-detection log would read
/// `sinceLastSeek=800005224.34s` (~25 years). The fix initializes the field
/// to `CFAbsoluteTimeGetCurrent()` at instance init time so the diagnostic
/// reads as plausible single-digit seconds.
///
/// **Accessor strategy:** uses `@testable import TAClient` + Swift's
/// `Mirror(reflecting:)` to read the `private nonisolated(unsafe)` field
/// without polluting the production type with a `_testLastSeekTimestamp`
/// getter. Mirror operates at the runtime metadata level and surfaces all
/// stored properties (including `private` and `nonisolated(unsafe)`),
/// regardless of access control. If a future Swift toolchain ever drops
/// reflection support for `nonisolated(unsafe)` storage, fall back to a
/// `#if DEBUG`-guarded internal getter on `VideoDetailViewModel`.
@MainActor
struct SeekTimestampInitTests {

    private func makeSUT() -> VideoDetailViewModel {
        let keychain = KeychainService()
        keychain.clearAll()
        let authState = AuthState(keychainService: keychain)
        let router = AppRouter(authState: authState)
        return VideoDetailViewModel(
            videoId: "test-video-id",
            videoRepository: MockVideoRepository(),
            authState: authState,
            router: router
        )
    }

    /// Pulls `lastExplicitSeekAt` out of the VM via Mirror. Returns nil if the
    /// field is missing or has an unexpected type — failing the calling test
    /// loudly rather than silently passing.
    private func readLastExplicitSeekAt(_ vm: VideoDetailViewModel) -> CFAbsoluteTime? {
        let mirror = Mirror(reflecting: vm)
        for child in mirror.children {
            if child.label == "lastExplicitSeekAt" {
                return child.value as? CFAbsoluteTime
            }
        }
        return nil
    }

    /// Freshly initialized VM must have `lastExplicitSeekAt` close to "now",
    /// not the CFAbsoluteTime epoch (Jan 1, 2001 → 0). Checking a ±2s window
    /// around the assertion's wall-clock time is enough to catch the old
    /// `= 0` default, which would manifest as ~800 million seconds of skew.
    @Test func freshVM_lastExplicitSeekAt_isInitializedToNow() {
        let before = CFAbsoluteTimeGetCurrent()
        let vm = makeSUT()
        let after = CFAbsoluteTimeGetCurrent()

        let value = readLastExplicitSeekAt(vm)
        #expect(value != nil, "Mirror failed to find lastExplicitSeekAt — did the field get renamed or moved?")

        guard let seekAt = value else { return }
        // The default expression for `lastExplicitSeekAt` runs during VM init,
        // which itself happens between the `before` and `after` samples.
        // Therefore `before <= seekAt <= after` must hold strictly — no slack
        // needed and no slack wanted (the original 1s lower-bound slack would
        // mask a regression to e.g. `= before - 0.5` if a future engineer ever
        // tried to fudge the diagnostic offset).
        #expect(seekAt >= before, "lastExplicitSeekAt=\(seekAt) is older than before=\(before) — defaulted to 0 or to a stale value?")
        #expect(seekAt <= after, "lastExplicitSeekAt=\(seekAt) is in the future relative to after=\(after)")
    }

    /// Sanity: the value is decisively NOT zero. Catches any regression that
    /// reverts the default to `= 0` even if `CFAbsoluteTimeGetCurrent()` ever
    /// reports a tiny positive value at process start.
    @Test func freshVM_lastExplicitSeekAt_isNotZero() {
        let vm = makeSUT()
        let value = readLastExplicitSeekAt(vm)
        #expect(value != nil)
        if let seekAt = value {
            #expect(seekAt > 1_000_000, "lastExplicitSeekAt=\(seekAt) looks like the old `= 0` default")
        }
    }

    /// The reset-timestamp helper called from the `stopPlayback()` `if let
    /// player` branch must return a "recent" CFAbsoluteTime, NEVER `0`. The
    /// earlier in-line `lastExplicitSeekAt = 0` reset re-introduced the
    /// cosmetic 25-year `[TailReplay] sinceLastSeek=...` skew on stop→re-start
    /// cycles; the static helper exists specifically so this contract is
    /// unit-testable without having to wire a real `AVPlayer` into a VM SUT
    /// (which is the only way to actually drive that branch in `stopPlayback`).
    ///
    /// Asserting `>= before && <= after` brackets the call, catching any
    /// regression to a stale or zero default with no slack to mask it.
    @Test func resetExplicitSeekTimestamp_returnsRecentValue() {
        let before = CFAbsoluteTimeGetCurrent()
        let value = VideoDetailViewModel.resetExplicitSeekTimestamp()
        let after = CFAbsoluteTimeGetCurrent()

        #expect(value >= before, "resetExplicitSeekTimestamp()=\(value) is older than before=\(before) — reverted to 0?")
        #expect(value <= after, "resetExplicitSeekTimestamp()=\(value) is in the future relative to after=\(after)")
    }

    /// Belt-and-suspenders sanity guard against any reversion that returns
    /// a tiny positive value (CFAbsoluteTime values for "now" are ~8x10^8).
    @Test func resetExplicitSeekTimestamp_isNotZero() {
        let value = VideoDetailViewModel.resetExplicitSeekTimestamp()
        #expect(value > 1_000_000, "resetExplicitSeekTimestamp()=\(value) looks like a reversion to `= 0`")
    }
}
