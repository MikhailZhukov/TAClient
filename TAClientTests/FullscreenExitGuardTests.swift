import Testing
import AVFoundation
@testable import TAClient

/// Pure-logic tests for `AVPlayerView.Coordinator.shouldResumePlayback(...)`,
/// the guard that decides whether to resume `.play()` after the user exits
/// fullscreen via the "Done" button.
///
/// **What these tests catch:** the tail-replay bug where AVPlayer reaches
/// end-of-stream during the ~400 ms fullscreen-exit animation, drops `rate` to
/// 0, auto-seeks back ~3 seconds, and then our delegate closure resumes
/// playback because the `wasPlaying` snapshot captured at `willEndFullScreen`
/// is still `true`. The guard re-checks the player's live `status` and
/// `currentTime` vs `duration` inside the closure to suppress the bogus
/// resume.
///
/// **What these tests do NOT cover:** the `AVPlayerViewControllerDelegate`
/// plumbing that wires the guard into the fullscreen-exit transition is
/// verified manually on a real iPad via Console log capture (see plan Task 2).
struct FullscreenExitGuardTests {

    // 1. wasPlaying=false, status=.paused, t=60, duration=120 → false
    //    User paused before tapping Done. Never resume.
    @Test func shouldResumePlayback_userPaused_returnsFalse() {
        let result = AVPlayerView.Coordinator.shouldResumePlayback(
            wasPlaying: false,
            status: .paused,
            currentTime: 60,
            duration: 120
        )
        #expect(result == false)
    }

    // 2. wasPlaying=true, status=.playing, t=60, duration=120 → true
    //    Mid-playback exit. Legitimate resume — preserved by the new guard.
    @Test func shouldResumePlayback_midPlaybackExit_returnsTrue() {
        let result = AVPlayerView.Coordinator.shouldResumePlayback(
            wasPlaying: true,
            status: .playing,
            currentTime: 60,
            duration: 120
        )
        #expect(result == true)
    }

    // 3. wasPlaying=true, status=.paused, t=120, duration=120 → false
    //    The bug being fixed: end-of-stream during animation. status went
    //    .playing→.paused mid-animation; the wasPlaying snapshot is stale.
    @Test func shouldResumePlayback_endOfStreamDuringAnimation_returnsFalse() {
        let result = AVPlayerView.Coordinator.shouldResumePlayback(
            wasPlaying: true,
            status: .paused,
            currentTime: 120,
            duration: 120
        )
        #expect(result == false)
    }

    // 4. wasPlaying=true, status=.playing, t=119.6, duration=120 → false
    //    Within 0.5s of duration. Belt-and-suspenders nearEnd guard catches the
    //    rare race where status hasn't yet transitioned but position is at end.
    @Test func shouldResumePlayback_nearEndStillPlaying_returnsFalse() {
        let result = AVPlayerView.Coordinator.shouldResumePlayback(
            wasPlaying: true,
            status: .playing,
            currentTime: 119.6,
            duration: 120
        )
        #expect(result == false)
    }

    // 5. wasPlaying=true, status=.playing, t=10, duration=.infinity → true
    //    Live stream. `currentTime >= .infinity - 0.5` is `currentTime >=
    //    .infinity`, which is false. So nearEnd=false and we resume.
    @Test func shouldResumePlayback_liveStreamInfiniteDuration_returnsTrue() {
        let result = AVPlayerView.Coordinator.shouldResumePlayback(
            wasPlaying: true,
            status: .playing,
            currentTime: 10,
            duration: .infinity
        )
        #expect(result == true)
    }

    // 6. wasPlaying=true, status=.playing, t=10, duration=.nan → true
    //    Item not yet loaded. Any comparison with NaN is false, so duration > 0
    //    is false → nearEnd=false → resume. Defensible: a not-yet-loaded item
    //    cannot possibly be at end-of-stream.
    @Test func shouldResumePlayback_nanDurationItemNotLoaded_returnsTrue() {
        let result = AVPlayerView.Coordinator.shouldResumePlayback(
            wasPlaying: true,
            status: .playing,
            currentTime: 10,
            duration: .nan
        )
        #expect(result == true)
    }

    // 7. wasPlaying=true, status=.waitingToPlayAtSpecifiedRate, t=60, duration=120 → false
    //    Buffering at exit. Strict status==.playing check matches the existing
    //    wasPlaying snapshot semantic. NOT a regression — pre-fix, wasPlaying
    //    would have been false in the same scenario.
    @Test func shouldResumePlayback_bufferingTreatedAsNotPlaying_returnsFalse() {
        let result = AVPlayerView.Coordinator.shouldResumePlayback(
            wasPlaying: true,
            status: .waitingToPlayAtSpecifiedRate,
            currentTime: 60,
            duration: 120
        )
        #expect(result == false)
    }
}
