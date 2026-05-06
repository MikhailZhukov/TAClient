import Testing
@testable import TAClient

/// Pure-logic tests for `VideoDetailViewModel.shouldSaveProgress(rate:seconds:lastAttempted:)`,
/// the guard that decides whether the 30s save observer should issue a
/// `saveProgress` POST.
///
/// **What these tests catch:** the end-of-stream regression bug where
/// AVPlayer's internal auto-seek-back ~3-6 seconds (preparing the system
/// "Replay" affordance) fires the periodic time observer with `rate == 0` and
/// a position less than `duration`, racing with `handleDidPlayToEnd()`'s final
/// `saveProgress(position: duration)` and often winning — leaving the server
/// with a regressed progress (e.g. 1004s for a 1010s video). The new
/// `rate > 0` guard suppresses saves whenever the player isn't actively
/// playing (pause, end-of-stream auto-seek-back).
///
/// **What these tests do NOT cover:** the AVFoundation `addPeriodicTimeObserver`
/// plumbing that wraps the helper is verified manually on a real iPad via
/// Console log capture (see plan Task 2).
struct ProgressSaveGuardTests {

    // 1. rate=1.0, seconds=60, lastAttempted=30 → true
    //    Normal advancing playback: rate>0, finite/positive seconds,
    //    delta=30 >= 1. Save proceeds.
    @Test func shouldSaveProgress_normalAdvancingPlayback_returnsTrue() {
        let result = VideoDetailViewModel.shouldSaveProgress(
            rate: 1.0,
            seconds: 60,
            lastAttempted: 30
        )
        #expect(result == true)
    }

    // 2. rate=0.0, seconds=60, lastAttempted=30 → false
    //    The bug case: AVPlayer auto-seek-back at end-of-stream has rate=0,
    //    but the observer fires anyway. New rate>0 guard blocks the save.
    @Test func shouldSaveProgress_pausedOrEndOfStreamSeekBack_returnsFalse() {
        let result = VideoDetailViewModel.shouldSaveProgress(
            rate: 0.0,
            seconds: 60,
            lastAttempted: 30
        )
        #expect(result == false)
    }

    // 3. rate=1.0, seconds=Double.nan, lastAttempted=30 → false
    //    Defensive: NaN seconds (not isFinite) — should never reach the server.
    @Test func shouldSaveProgress_nanSeconds_returnsFalse() {
        let result = VideoDetailViewModel.shouldSaveProgress(
            rate: 1.0,
            seconds: Double.nan,
            lastAttempted: 30
        )
        #expect(result == false)
    }

    // 4. rate=1.0, seconds=-1, lastAttempted=30 → false
    //    Defensive: negative seconds — pre-roll / not-ready state.
    @Test func shouldSaveProgress_negativeSeconds_returnsFalse() {
        let result = VideoDetailViewModel.shouldSaveProgress(
            rate: 1.0,
            seconds: -1,
            lastAttempted: 30
        )
        #expect(result == false)
    }

    // 5. rate=1.0, seconds=30.5, lastAttempted=30 → false
    //    Debounce: within 1s of lastAttempted. Skip the POST to avoid spamming
    //    the server with sub-second updates during a normal 1Hz observer tick.
    @Test func shouldSaveProgress_withinDebounceWindow_returnsFalse() {
        let result = VideoDetailViewModel.shouldSaveProgress(
            rate: 1.0,
            seconds: 30.5,
            lastAttempted: 30
        )
        #expect(result == false)
    }

    // 6. rate=1.0, seconds=29.5, lastAttempted=30 → false
    //    Debounce should reject sub-1s deltas during active playback.
    //    |29.5 - 30| = 0.5 < 1 → false.
    @Test func shouldSaveProgress_rateOneSmallBackwardDelta_returnsFalse() {
        let result = VideoDetailViewModel.shouldSaveProgress(
            rate: 1.0,
            seconds: 29.5,
            lastAttempted: 30
        )
        #expect(result == false)
    }

    // 7. rate=2.0, seconds=60, lastAttempted=30 → true
    //    rate>0 includes any positive rate, e.g. 2x playback. Save proceeds.
    @Test func shouldSaveProgress_doubleSpeedPlayback_returnsTrue() {
        let result = VideoDetailViewModel.shouldSaveProgress(
            rate: 2.0,
            seconds: 60,
            lastAttempted: 30
        )
        #expect(result == true)
    }

    // 8. rate=Float.nan, seconds=60, lastAttempted=30 → false
    //    Defensive: NaN rate is not playing. Any comparison with NaN is false,
    //    so `rate > 0` is false → guard blocks the save. Correct classification
    //    for a not-yet-loaded player.
    @Test func shouldSaveProgress_nanRate_returnsFalse() {
        let result = VideoDetailViewModel.shouldSaveProgress(
            rate: Float.nan,
            seconds: 60,
            lastAttempted: 30
        )
        #expect(result == false)
    }

    // 9. rate=1.0, seconds=31, lastAttempted=30 → true
    //    Boundary: `abs(31 - 30) == 1.0` exactly, helper uses `>= 1` so save
    //    proceeds. Pins the inclusive lower edge of the debounce window.
    @Test func shouldSaveProgress_exactBoundaryForward_returnsTrue() {
        let result = VideoDetailViewModel.shouldSaveProgress(
            rate: 1.0,
            seconds: 31,
            lastAttempted: 30
        )
        #expect(result == true)
    }

    // 10. rate=1.0, seconds=29, lastAttempted=30 → true
    //     Boundary: `abs(29 - 30) == 1.0` exactly, helper uses `>= 1` so save
    //     proceeds even on a backward delta of 1.0. Pins the symmetric edge
    //     of the `abs() >= 1` semantic.
    @Test func shouldSaveProgress_exactBoundaryBackward_returnsTrue() {
        let result = VideoDetailViewModel.shouldSaveProgress(
            rate: 1.0,
            seconds: 29,
            lastAttempted: 30
        )
        #expect(result == true)
    }

    // 11. rate=-1.0, seconds=60, lastAttempted=30 → false
    //     Defensive: reverse playback (`Float` allows negative rates). Helper's
    //     `rate > 0` correctly suppresses the save — we don't want to persist
    //     a regressed position to the server during scrub-back / reverse.
    @Test func shouldSaveProgress_reversePlaybackRate_returnsFalse() {
        let result = VideoDetailViewModel.shouldSaveProgress(
            rate: -1.0,
            seconds: 60,
            lastAttempted: 30
        )
        #expect(result == false)
    }

    // 12. rate=1.0, seconds=0, lastAttempted=-1 → false
    //     Boundary: `seconds > 0` is strict, so `seconds == 0` is rejected.
    //     Avoids POSTing an "at the very start" sample on the first tick of
    //     a freshly-loaded video.
    @Test func shouldSaveProgress_zeroSeconds_returnsFalse() {
        let result = VideoDetailViewModel.shouldSaveProgress(
            rate: 1.0,
            seconds: 0,
            lastAttempted: -1
        )
        #expect(result == false)
    }
}
