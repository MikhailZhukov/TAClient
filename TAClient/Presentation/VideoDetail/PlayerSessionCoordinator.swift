import Foundation
import AVFoundation
import OSLog

private let logger = Logger(subsystem: "ru.mzhukov.TAClient", category: "PlayerSessionCoordinator")

/// Coordinates audio-session plumbing for an active AVPlayer session:
/// interruptions (phone calls, Siri), route changes (headphones unplugged,
/// AirPlay becoming active), and media-services reset.
///
/// VM owns one coordinator per playback session. Call `start()` when playback
/// begins, `stop()` when playback ends. Callbacks fire on the main queue.
@MainActor
final class PlayerSessionCoordinator {

    // MARK: - Public callbacks

    /// Fires on `AVAudioSession.interruptionNotification` with type `.began`
    /// (e.g. phone call arrived, Siri activated).
    var onInterruptionBegan: (() -> Void)?

    /// Fires on `.interruptionNotification` with type `.ended`. The `Bool`
    /// parameter is `true` when the system indicates `.shouldResume`
    /// (playback should automatically resume), `false` otherwise.
    var onInterruptionEnded: ((Bool) -> Void)?

    /// Fires on `routeChangeNotification` with reason `.oldDeviceUnavailable`
    /// — typical trigger: headphones / Bluetooth headset unplugged.
    /// Apple HIG: playback MUST pause automatically.
    var onHeadphonesUnplugged: (() -> Void)?

    /// Fires on `routeChangeNotification` when AirPlay becomes the active
    /// output (new device available, override, or route config change with
    /// AirPlay in current outputs).
    var onAirPlayBecameActive: (() -> Void)?

    /// Fires on `AVAudioSession.mediaServicesWereResetNotification` —
    /// audio stack was torn down by iOS (rare; simulator hibernation, OS
    /// audio daemon crash). All audio objects are invalidated and must be
    /// rebuilt. VM should stop playback and surface an error.
    var onMediaServicesReset: (() -> Void)?

    // MARK: - Private state

    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var mediaServicesResetObserver: NSObjectProtocol?
    private var isStarted = false

    // MARK: - Lifecycle

    init() {}

    deinit {
        // Safety net: VM should call `stop()` explicitly, but if it forgets
        // (e.g. deinit without passing through `stopPlayback()`), clear our
        // NotificationCenter observers so we don't leak callbacks.
        // Note: cannot call `stop()` directly because it's MainActor-isolated
        // and deinit is nonisolated. Observer removal is thread-safe.
        if let token = interruptionObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = routeChangeObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = mediaServicesResetObserver {
            NotificationCenter.default.removeObserver(token)
        }
        // If `stop()` was never called but we had activated the audio session
        // in `start()`, try to deactivate with `.notifyOthersOnDeactivation`
        // so Music/Podcasts can resume. `setActive(false:)` is documented as
        // thread-safe and can be invoked from any thread.
        if isStarted {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }

    /// Registers all three notification observers and activates the audio
    /// session. Idempotent — calling twice without an intermediate `stop()`
    /// is a no-op on the second call.
    func start() {
        guard !isStarted else { return }
        isStarted = true

        let center = NotificationCenter.default

        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.handleInterruption(note)
            }
        }

        routeChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.handleRouteChange(note)
            }
        }

        mediaServicesResetObserver = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                logger.warning("Media services were reset — notifying VM")
                self.onMediaServicesReset?()
            }
        }

        // Defer audio-session activation until playback actually starts —
        // avoids stealing audio focus from Music/Podcasts while the user is
        // merely browsing the app.
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            logger.warning("Failed to activate AVAudioSession: \(error.localizedDescription)")
        }
    }

    /// Removes observers and deactivates the audio session, notifying other
    /// audio apps so they can resume (App Review expectation).
    func stop() {
        guard isStarted else { return }
        isStarted = false

        let center = NotificationCenter.default
        if let token = interruptionObserver {
            center.removeObserver(token)
            interruptionObserver = nil
        }
        if let token = routeChangeObserver {
            center.removeObserver(token)
            routeChangeObserver = nil
        }
        if let token = mediaServicesResetObserver {
            center.removeObserver(token)
            mediaServicesResetObserver = nil
        }

        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        } catch {
            logger.warning("Failed to deactivate AVAudioSession: \(error.localizedDescription)")
        }
    }

    // MARK: - Notification handlers

    private func handleInterruption(_ note: Notification) {
        // CRITICAL: userInfo values are boxed as `UInt` (NSNumber unsigned).
        // Casting to `Int` silently fails to construct the enum.
        guard let info = note.userInfo,
              let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else {
            return
        }

        switch type {
        case .began:
            logger.info("Interruption began")
            onInterruptionBegan?()

        case .ended:
            var shouldResume = false
            if let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                shouldResume = options.contains(.shouldResume)
            }
            logger.info("Interruption ended, shouldResume=\(shouldResume)")
            onInterruptionEnded?(shouldResume)

        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let reasonRaw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else {
            return
        }

        switch reason {
        case .oldDeviceUnavailable:
            logger.info("Route change: old device unavailable (headphones unplugged)")
            onHeadphonesUnplugged?()

        case .newDeviceAvailable, .override, .routeConfigurationChange:
            if isAirPlayActive() {
                logger.info("Route change: AirPlay became active (reason=\(reasonRaw))")
                onAirPlayBecameActive?()
            }

        default:
            break
        }
    }

    private func isAirPlayActive() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
    }
}
