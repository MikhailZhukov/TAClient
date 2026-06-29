import Testing
import AVFoundation
import AVKit
import SwiftUI
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

/// Pure-logic tests for `AVPlayerView.Coordinator.shouldClampToEnd(...)`,
/// the guard that decides whether to force-seek back to exact `duration`
/// after fullscreen exit when AVKit's internal "Replay-affordance" seek-back
/// has drifted `currentTime` away from the natural end of stream.
///
/// **What these tests catch:** AVKit's undocumented behavior where, after
/// `AVPlayerItemDidPlayToEndTime` fires with `actionAtItemEnd = .pause`,
/// AVKit asynchronously seeks the item back ~3-7 seconds to a previous
/// keyframe so the system "Replay" button has somewhere to start from.
/// When this happens during fullscreen-exit animation, the player is left
/// resting at the seeked-back position rather than at duration, visually
/// showing a frame from several seconds before the end.
///
/// The helper takes a boolean `didPlayToEnd` flag (set by the existing
/// `AVPlayerItemDidPlayToEndTime` notification observer in `Coordinator`)
/// rather than a position threshold — production logs show drifts of
/// 4.22s and 7.54s, far past any reasonable threshold, and `currentTime`
/// is unreliable here because AVKit's seek-back is async w.r.t. our
/// completion block.
///
/// **What these tests do NOT cover:** the wiring that sets `didPlayToEnd
/// = true` from the notification observer, the `coordinator.animate`
/// completion's branch into `seek(to: duration, .zero, .zero)`, and the
/// 150ms re-clamp via `DispatchQueue.main.asyncAfter`. Those are verified
/// manually on a real iPad via Console log capture (see plan Post-Completion).
struct ShouldClampToEndTests {

    // 1. didPlayToEnd=false, status=.paused, duration=120 → false
    //    No end-of-stream signal. SponsorBlock skips that land near
    //    duration but don't fire DidPlayToEnd take this path; clamp must
    //    NOT fire and steal control from legitimate seeks.
    @Test func shouldClampToEnd_noEndSignal_returnsFalse() {
        let result = AVPlayerView.Coordinator.shouldClampToEnd(
            didPlayToEnd: false,
            duration: 120,
            status: .paused
        )
        #expect(result == false)
    }

    // 2. didPlayToEnd=true, status=.paused, duration=120 → true
    //    The bug being fixed: end fired, AVKit paused the player, AVKit
    //    seek-back may have already drifted currentTime. Clamp.
    @Test func shouldClampToEnd_endFiredAndPaused_returnsTrue() {
        let result = AVPlayerView.Coordinator.shouldClampToEnd(
            didPlayToEnd: true,
            duration: 120,
            status: .paused
        )
        #expect(result == true)
    }

    // 3. didPlayToEnd=true, status=.playing, duration=120 → false
    //    Still playing — `shouldResumePlayback` handles this branch;
    //    clamping here would interrupt legitimate playback.
    @Test func shouldClampToEnd_endFiredButStillPlaying_returnsFalse() {
        let result = AVPlayerView.Coordinator.shouldClampToEnd(
            didPlayToEnd: true,
            duration: 120,
            status: .playing
        )
        #expect(result == false)
    }

    // 4. didPlayToEnd=true, status=.waitingToPlayAtSpecifiedRate, duration=120 → false
    //    Buffering edge case. Don't interrupt the loader; if buffering
    //    resolves to playing, the still-playing path covers it; if it
    //    resolves to paused, the next predicate evaluation catches it.
    @Test func shouldClampToEnd_endFiredButBuffering_returnsFalse() {
        let result = AVPlayerView.Coordinator.shouldClampToEnd(
            didPlayToEnd: true,
            duration: 120,
            status: .waitingToPlayAtSpecifiedRate
        )
        #expect(result == false)
    }

    // 5. didPlayToEnd=true, status=.paused, duration=.infinity → false
    //    Live stream. Should never receive DidPlayToEnd in practice, but
    //    guard explicitly: nothing to clamp to on an infinite timeline.
    @Test func shouldClampToEnd_infiniteDuration_returnsFalse() {
        let result = AVPlayerView.Coordinator.shouldClampToEnd(
            didPlayToEnd: true,
            duration: .infinity,
            status: .paused
        )
        #expect(result == false)
    }

    // 6. didPlayToEnd=true, status=.paused, duration=.nan → false
    //    Item not loaded; nonsensical state. Any comparison with NaN is
    //    false, so the finite-positive guard rejects.
    @Test func shouldClampToEnd_nanDuration_returnsFalse() {
        let result = AVPlayerView.Coordinator.shouldClampToEnd(
            didPlayToEnd: true,
            duration: .nan,
            status: .paused
        )
        #expect(result == false)
    }

    // 7. didPlayToEnd=true, status=.paused, duration=0 → false
    //    Zero or garbage duration. Nothing meaningful to clamp to.
    @Test func shouldClampToEnd_zeroDuration_returnsFalse() {
        let result = AVPlayerView.Coordinator.shouldClampToEnd(
            didPlayToEnd: true,
            duration: 0,
            status: .paused
        )
        #expect(result == false)
    }

    // 7b. didPlayToEnd=true, status=.paused, duration=-1 → false
    //    Negative duration is nonsensical; the `> 0` half of the
    //    finite-positive guard rejects it. Locks the predicate against
    //    a future relaxation to `>= 0` that would let zero/negative
    //    durations through.
    @Test func shouldClampToEnd_negativeDuration_returnsFalse() {
        let result = AVPlayerView.Coordinator.shouldClampToEnd(
            didPlayToEnd: true,
            duration: -1,
            status: .paused
        )
        #expect(result == false)
    }

    // 8. Mutual-exclusivity sanity check vs `shouldResumePlayback`.
    //    For end-of-stream input, only one of the two predicates may
    //    return true. `shouldResumePlayback` requires status == .playing
    //    AND not-near-end; `shouldClampToEnd` requires status == .paused
    //    AND didPlayToEnd. Iterate the realistic state space and assert
    //    no input combination triggers both.
    @Test func shouldClampToEnd_mutuallyExclusiveWithShouldResume() {
        let statuses: [AVPlayer.TimeControlStatus] = [
            .paused, .playing, .waitingToPlayAtSpecifiedRate
        ]
        let didPlayToEndOptions = [false, true]
        let wasPlayingOptions = [false, true]
        let times: [Double] = [0, 60, 119.6, 120]
        let duration: Double = 120

        // Positive-coverage anchor: at least one input combination must drive
        // the clamp predicate true, otherwise a regression that breaks BOTH
        // predicates at end-of-stream (returning false everywhere) would
        // satisfy the `!(resume && clamp)` invariant vacuously.
        var clampFiredAtLeastOnce = false
        var resumeFiredAtLeastOnce = false

        for status in statuses {
            for didPlayToEnd in didPlayToEndOptions {
                for wasPlaying in wasPlayingOptions {
                    for currentTime in times {
                        let resume = AVPlayerView.Coordinator.shouldResumePlayback(
                            wasPlaying: wasPlaying,
                            status: status,
                            currentTime: currentTime,
                            duration: duration
                        )
                        let clamp = AVPlayerView.Coordinator.shouldClampToEnd(
                            didPlayToEnd: didPlayToEnd,
                            duration: duration,
                            status: status
                        )
                        #expect(
                            !(resume && clamp),
                            "predicates both true for status=\(status) didPlayToEnd=\(didPlayToEnd) wasPlaying=\(wasPlaying) t=\(currentTime)"
                        )
                        if clamp { clampFiredAtLeastOnce = true }
                        if resume { resumeFiredAtLeastOnce = true }
                    }
                }
            }
        }

        // Specific positive assertion for the bug-fix branch: the canonical
        // end-of-stream input (didPlayToEnd=true, status=.paused, duration>0)
        // must drive clamp=true. Catches a regression like flipping the
        // `guard didPlayToEnd` to `guard !didPlayToEnd`.
        let canonicalClamp = AVPlayerView.Coordinator.shouldClampToEnd(
            didPlayToEnd: true,
            duration: duration,
            status: .paused
        )
        #expect(canonicalClamp == true, "canonical clamp-fix input must return true")
        #expect(clampFiredAtLeastOnce, "no input drove clamp=true — predicate may be uniformly false")
        #expect(resumeFiredAtLeastOnce, "no input drove resume=true — predicate may be uniformly false")
    }
}

/// Wiring tests for the `didPlayToEnd` Coordinator flag. The pure predicates
/// (`shouldClampToEnd`, `shouldClearEndFlag`) are covered above; this suite
/// validates the *flag mutation* paths:
///
/// 1. Initial value: false (no end-of-stream signal yet).
/// 2. `AVPlayerItemDidPlayToEndTime` notification → flag flips true.
/// 3. `observeEnd` rewiring with a new item resets the flag to false.
///
/// The `timeJumpedNotification` reset path is intentionally NOT exercised
/// here as a wiring test. The closure body is a one-liner that delegates to
/// the pure `shouldClearEndFlag(currentTime:duration:)` predicate, which has
/// dedicated table-driven tests in `ShouldClearEndFlagTests` above. Driving
/// the wiring would require posting `timeJumpedNotification` against an
/// `AVPlayerItem` whose `currentTime`/`duration` we can control — `about:blank`
/// items report `.indefinite` duration, so the predicate would always reject
/// regardless of the flag mutation logic. The two-test split (predicate +
/// mutation) keeps each test focused and avoids needing AVPlayer fixtures.
///
/// Uses Mirror reflection to read the `private` flag — same approach as
/// `SeekTimestampInitTests`, no production-API pollution.
@MainActor
struct CoordinatorEndFlagWiringTests {

    private func makeCoordinator() -> AVPlayerView.Coordinator {
        var fs = false
        var pip = false
        return AVPlayerView.Coordinator(
            isFullScreen: Binding(get: { fs }, set: { fs = $0 }),
            isPiPActive: Binding(get: { pip }, set: { pip = $0 }),
            onPiPStopped: nil
        )
    }

    private func readDidPlayToEnd(_ coord: AVPlayerView.Coordinator) -> Bool? {
        for child in Mirror(reflecting: coord).children {
            if child.label == "didPlayToEnd" {
                return child.value as? Bool
            }
        }
        return nil
    }

    /// Empty-asset AVPlayerItem; duration is `.indefinite`. We post the
    /// notifications by hand on `NotificationCenter.default`, so the item
    /// content doesn't actually matter — only the `object:` identity does.
    private func makeStubItem() -> AVPlayerItem {
        AVPlayerItem(url: URL(string: "about:blank")!)
    }

    @Test func didPlayToEndFlag_initiallyFalse() {
        let coord = makeCoordinator()
        #expect(readDidPlayToEnd(coord) == false)
    }

    @Test func didPlayToEndFlag_setsTrueOnEndNotification() {
        let coord = makeCoordinator()
        let item = makeStubItem()
        let vc = AVPlayerViewController()
        coord.observeEnd(of: item, playerVC: vc)

        NotificationCenter.default.post(
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )
        // Observer queue is .main; we're already on MainActor and the post
        // is synchronous-on-main when the observer was registered with
        // `queue: .main` and the post happens on main.
        #expect(readDidPlayToEnd(coord) == true)
    }

    @Test func didPlayToEndFlag_resetsOnObserveEndOfNewItem() {
        let coord = makeCoordinator()
        let item1 = makeStubItem()
        let vc = AVPlayerViewController()
        coord.observeEnd(of: item1, playerVC: vc)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item1)
        #expect(readDidPlayToEnd(coord) == true)

        // Rewire to a new item — flag should reset.
        let item2 = makeStubItem()
        coord.observeEnd(of: item2, playerVC: vc)
        #expect(readDidPlayToEnd(coord) == false)
    }

    /// Coverage for the AirPlay swap path — `VideoDetailViewModel.handleAirPlayBecameActive`
    /// calls `player.replaceCurrentItem(with:)` on the same `AVPlayer`, which used to
    /// silently leave the Coordinator's notification observers bound to the discarded
    /// item. After the fix, a `currentItem` KVO re-invokes `observeEnd` with the new
    /// item: the flag resets to false AND the end-notification rebinds to the new item.
    ///
    /// This test drives the swap programmatically and asserts both halves of the
    /// invariant: (1) `didPlayToEnd` flips back to false after the swap, (2) posting
    /// the end notification against the NEW item flips it back to true (proves the
    /// observer re-bound), (3) posting the end notification against the OLD item is
    /// a no-op (proves the old observer was torn down).
    @Test func didPlayToEndFlag_resetsAndRebindsOnReplaceCurrentItem() async {
        let coord = makeCoordinator()
        let item1 = makeStubItem()
        let player = AVPlayer(playerItem: item1)
        let vc = AVPlayerViewController()
        vc.player = player
        coord.observeEnd(of: item1, playerVC: vc)

        // Drive the flag true via the original item's end notification.
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item1)
        #expect(readDidPlayToEnd(coord) == true)

        // The fix under test: replaceCurrentItem(with:) — same player, new item.
        // The currentItem KVO must re-invoke observeEnd, resetting the flag.
        let item2 = makeStubItem()
        player.replaceCurrentItem(with: item2)
        // KVO callbacks dispatch on the posting thread; replaceCurrentItem is
        // documented as fast-but-not-strictly-sync. Yield once to let any
        // async hop settle before reading the flag.
        await Task.yield()
        #expect(readDidPlayToEnd(coord) == false, "currentItem swap must reset didPlayToEnd")

        // New item observer must be wired: posting end on item2 flips flag true.
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item2)
        #expect(readDidPlayToEnd(coord) == true, "new item end-notification must set flag (observer rebound)")

        // Old item observer must be torn down: posting end on item1 is a no-op.
        // Reset the flag back to false manually via another KVO swap, then prove
        // posting on item1 doesn't move it.
        let item3 = makeStubItem()
        player.replaceCurrentItem(with: item3)
        await Task.yield()
        #expect(readDidPlayToEnd(coord) == false)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item1)
        #expect(readDidPlayToEnd(coord) == false, "stale item1 end-notification must NOT set flag (old observer torn down)")
    }
}

/// Pure-logic tests for `AVPlayerView.Coordinator.shouldClearEndFlag(...)`,
/// the predicate that decides whether an `AVPlayerItem.timeJumpedNotification`
/// should clear the `didPlayToEnd` flag.
///
/// **Why this matters:** the `didPlayToEnd` flag drives `shouldClampToEnd`.
/// A naive "back from end by N seconds" threshold (e.g. `currentTime <
/// duration - 1.0`) is defeated by the very pattern the clamp exists to fix —
/// production logs measured AVKit's own seek-back-for-Replay drift at 4-8s
/// before duration, which would satisfy any "duration - 1.0" boundary and
/// erroneously clear the flag, taking the clamp path off the table.
///
/// The correct boundary is "near zero" — the user's Replay button always
/// seeks the same item back to position ~0; AVKit's drift never lands near 0
/// on any video longer than ~10 seconds. The two paths are cleanly separable.
struct ShouldClearEndFlagTests {

    // 1. Replay button: user taps system Replay → AVKit seeks to 0. Clear.
    @Test func shouldClearEndFlag_replayToZero_returnsTrue() {
        #expect(AVPlayerView.Coordinator.shouldClearEndFlag(currentTime: 0, duration: 120) == true)
    }

    // 1b. Tiny positive — AVKit may land at fractional seconds, still Replay.
    @Test func shouldClearEndFlag_replayToNearZero_returnsTrue() {
        #expect(AVPlayerView.Coordinator.shouldClearEndFlag(currentTime: 0.3, duration: 120) == true)
    }

    // 2. AVKit drift back ~4s — must KEEP the flag set so clamp path fires.
    //    Mirrors production log delta=4.22s.
    @Test func shouldClearEndFlag_avkitDriftBack4s_returnsFalse() {
        #expect(AVPlayerView.Coordinator.shouldClearEndFlag(currentTime: 1100.0, duration: 1104.0) == false)
    }

    // 3. AVKit drift back ~7.5s — must KEEP the flag set. Mirrors production
    //    log delta=7.54s. This is the key regression case for Finding #1: a
    //    `< duration - 1.0` threshold would ERRONEOUSLY return true here and
    //    silently disable the clamp fix.
    @Test func shouldClearEndFlag_avkitDriftBack7p5s_returnsFalse() {
        #expect(AVPlayerView.Coordinator.shouldClearEndFlag(currentTime: 519.76, duration: 527.0) == false)
    }

    // 4. Mid-playback time-jump — neither Replay nor AVKit drift; keep flag
    //    set since shouldClampToEnd will reject anyway when not paused.
    @Test func shouldClearEndFlag_midPlayback_returnsFalse() {
        #expect(AVPlayerView.Coordinator.shouldClearEndFlag(currentTime: 60, duration: 120) == false)
    }

    // 5. Position exactly at the 1.0 threshold — `< 1.0` is false at 1.0 by
    //    definition. Locks the strict-less-than boundary.
    @Test func shouldClearEndFlag_atThresholdBoundary_returnsFalse() {
        #expect(AVPlayerView.Coordinator.shouldClearEndFlag(currentTime: 1.0, duration: 120) == false)
    }

    // 6. Defensive shape: infinite duration (live stream) → never clear.
    @Test func shouldClearEndFlag_infiniteDuration_returnsFalse() {
        #expect(AVPlayerView.Coordinator.shouldClearEndFlag(currentTime: 0, duration: .infinity) == false)
    }

    // 7. Defensive shape: NaN / zero / negative duration → never clear.
    @Test func shouldClearEndFlag_nanDuration_returnsFalse() {
        #expect(AVPlayerView.Coordinator.shouldClearEndFlag(currentTime: 0, duration: .nan) == false)
    }

    @Test func shouldClearEndFlag_zeroDuration_returnsFalse() {
        #expect(AVPlayerView.Coordinator.shouldClearEndFlag(currentTime: 0, duration: 0) == false)
    }

    @Test func shouldClearEndFlag_negativeDuration_returnsFalse() {
        #expect(AVPlayerView.Coordinator.shouldClearEndFlag(currentTime: 0, duration: -1) == false)
    }

    // 8. Defensive shape: NaN currentTime → never clear (item not loaded).
    @Test func shouldClearEndFlag_nanCurrentTime_returnsFalse() {
        #expect(AVPlayerView.Coordinator.shouldClearEndFlag(currentTime: .nan, duration: 120) == false)
    }
}
