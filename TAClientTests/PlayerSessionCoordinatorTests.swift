import Testing
import Foundation
import AVFoundation
@testable import TAClient

/// Tests for A1 (Task 4): `PlayerSessionCoordinator` routes audio-session
/// notifications (interruption, route change, media services reset) to
/// callbacks supplied by the VM.
///
/// Tests post notifications directly through `NotificationCenter.default`
/// with synthetic `userInfo` payloads — the coordinator is unit-testable
/// without a real AVPlayer.
@MainActor
@Suite(.serialized) struct PlayerSessionCoordinatorTests {

    // MARK: - Helpers
    //
    // Uses shared `waitForCondition` from `TestHelpers.swift`. Renamed locally
    // as `waitForCallback` at call sites in the original suite — migrated to
    // the shared name in this pass.

    // MARK: - Interruption

    @Test func interruptionBegan_invokesCallback() async {
        let coordinator = PlayerSessionCoordinator()
        var didFire = false
        coordinator.onInterruptionBegan = { didFire = true }
        coordinator.start()
        defer { coordinator.stop() }

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: UInt(AVAudioSession.InterruptionType.began.rawValue)
            ]
        )

        let fired = await waitForCondition({ didFire })
        #expect(fired, "Expected onInterruptionBegan to fire")
    }

    @Test func interruptionEnded_withShouldResume_invokesCallbackWithTrue() async {
        let coordinator = PlayerSessionCoordinator()
        var resumeFlag: Bool?
        coordinator.onInterruptionEnded = { shouldResume in resumeFlag = shouldResume }
        coordinator.start()
        defer { coordinator.stop() }

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: UInt(AVAudioSession.InterruptionType.ended.rawValue),
                AVAudioSessionInterruptionOptionKey: UInt(AVAudioSession.InterruptionOptions.shouldResume.rawValue)
            ]
        )

        let fired = await waitForCondition({ resumeFlag != nil })
        #expect(fired, "Expected onInterruptionEnded to fire")
        #expect(resumeFlag == true, "Expected shouldResume=true")
    }

    @Test func interruptionEnded_withoutShouldResume_invokesCallbackWithFalse() async {
        let coordinator = PlayerSessionCoordinator()
        var resumeFlag: Bool?
        coordinator.onInterruptionEnded = { shouldResume in resumeFlag = shouldResume }
        coordinator.start()
        defer { coordinator.stop() }

        // Post with no options payload — must resolve to shouldResume=false.
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: UInt(AVAudioSession.InterruptionType.ended.rawValue)
            ]
        )

        let fired = await waitForCondition({ resumeFlag != nil })
        #expect(fired, "Expected onInterruptionEnded to fire")
        #expect(resumeFlag == false, "Expected shouldResume=false when option missing")
    }

    // MARK: - Route change

    @Test func routeChange_oldDeviceUnavailable_invokesHeadphonesCallback() async {
        let coordinator = PlayerSessionCoordinator()
        var didFire = false
        coordinator.onHeadphonesUnplugged = { didFire = true }
        coordinator.start()
        defer { coordinator.stop() }

        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: [
                AVAudioSessionRouteChangeReasonKey: UInt(AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue)
            ]
        )

        let fired = await waitForCondition({ didFire })
        #expect(fired, "Expected onHeadphonesUnplugged to fire on .oldDeviceUnavailable")
    }

    @Test func routeChange_categoryChange_doesNotFireHeadphones() async {
        // Sanity check: unrelated reasons must not fire the headphones
        // callback. AirPlay callback is contingent on current route outputs
        // which we cannot synthetically modify from a test, so this just
        // verifies the headphones path is specific to `.oldDeviceUnavailable`.
        let coordinator = PlayerSessionCoordinator()
        var didFire = false
        coordinator.onHeadphonesUnplugged = { didFire = true }
        coordinator.start()
        defer { coordinator.stop() }

        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: [
                AVAudioSessionRouteChangeReasonKey: UInt(AVAudioSession.RouteChangeReason.categoryChange.rawValue)
            ]
        )

        // Small delay to let any stray posts drain.
        try? await Task.sleep(for: .milliseconds(150))
        #expect(didFire == false, "Headphones callback should not fire on .categoryChange")

        // Positive control: post a `.oldDeviceUnavailable` afterwards. The
        // observer must still be live (i.e. `start()` wasn't a no-op — this
        // would be the only way the preceding negative assertion could vacuously
        // pass). If this fires, we've proven both: start() registered, AND
        // categoryChange genuinely didn't trigger the callback.
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: [
                AVAudioSessionRouteChangeReasonKey: UInt(AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue)
            ]
        )

        let fired = await waitForCondition({ didFire })
        #expect(fired, "Positive control: observer must still be live after categoryChange")
    }

    // MARK: - Media services reset

    @Test func mediaServicesReset_invokesCallback() async {
        let coordinator = PlayerSessionCoordinator()
        var didFire = false
        coordinator.onMediaServicesReset = { didFire = true }
        coordinator.start()
        defer { coordinator.stop() }

        NotificationCenter.default.post(
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )

        let fired = await waitForCondition({ didFire })
        #expect(fired, "Expected onMediaServicesReset to fire")
    }

    // MARK: - Lifecycle

    @Test func stop_removesObservers() async {
        let coordinator = PlayerSessionCoordinator()
        var interruptionFireCount = 0
        var routeFireCount = 0
        var mediaResetFireCount = 0
        coordinator.onInterruptionBegan = { interruptionFireCount += 1 }
        coordinator.onHeadphonesUnplugged = { routeFireCount += 1 }
        coordinator.onMediaServicesReset = { mediaResetFireCount += 1 }
        coordinator.start()
        coordinator.stop()

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: UInt(AVAudioSession.InterruptionType.began.rawValue)
            ]
        )
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: [
                AVAudioSessionRouteChangeReasonKey: UInt(AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue)
            ]
        )
        NotificationCenter.default.post(
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )

        try? await Task.sleep(for: .milliseconds(150))
        #expect(interruptionFireCount == 0, "Interruption callback must not fire after stop()")
        #expect(routeFireCount == 0, "Route change callback must not fire after stop()")
        #expect(mediaResetFireCount == 0, "Media reset callback must not fire after stop()")
    }

    @Test func start_isIdempotent() async {
        // Calling start() twice must not double-register observers
        // (otherwise the callback would fire twice per notification).
        let coordinator = PlayerSessionCoordinator()
        var fireCount = 0
        coordinator.onInterruptionBegan = { fireCount += 1 }
        coordinator.start()
        coordinator.start()
        defer { coordinator.stop() }

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: UInt(AVAudioSession.InterruptionType.began.rawValue)
            ]
        )

        try? await Task.sleep(for: .milliseconds(150))
        #expect(fireCount == 1, "Expected exactly one callback even after double start()")
    }

    @Test func stop_isIdempotent() async {
        let coordinator = PlayerSessionCoordinator()
        coordinator.start()
        coordinator.stop()
        coordinator.stop() // must not crash or throw
        #expect(Bool(true))
    }

    @Test func callbackNotInvokedBeforeStart() async {
        // Observers are registered in start(), not in init. Posting a
        // notification before start() must not fire callbacks.
        let coordinator = PlayerSessionCoordinator()
        var didFire = false
        coordinator.onInterruptionBegan = { didFire = true }

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: UInt(AVAudioSession.InterruptionType.began.rawValue)
            ]
        )

        try? await Task.sleep(for: .milliseconds(150))
        #expect(didFire == false, "Callback should not fire before start()")

        // Cleanup — ensure deinit path with no started state is also safe.
        _ = coordinator
    }
}
