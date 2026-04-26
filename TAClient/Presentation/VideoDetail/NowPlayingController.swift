import Foundation
import AVFoundation
import AVKit
import MediaPlayer
import UIKit
import OSLog

private let logger = Logger(subsystem: "ru.mzhukov.TAClient", category: "NowPlayingController")

/// Drives `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` for an active
/// AVPlayer session. Registers play/pause/toggle/skipForward/skipBackward/
/// changePlaybackPosition remote commands, routing them into VM-supplied
/// callbacks. VLC playback is intentionally NOT supported by this controller —
/// the VLC code path bypasses `MPNowPlayingInfoCenter` entirely.
///
/// Lifecycle: VM creates the controller when playback starts, calls `start()`
/// to publish initial metadata + register command targets, calls `refresh()`
/// at key moments (time observer tick, interruption resume, stall recovery),
/// and calls `stop()` when playback ends to clear now-playing info and
/// detach command targets.
@MainActor
final class NowPlayingController {

    // MARK: - Inputs

    private let player: AVPlayer
    private let video: Video
    private let imageCache: ImageCache
    private let seekInterval: Int
    private let onPlay: () -> Void
    private let onPause: () -> Void
    private let onSeek: (TimeInterval) -> Void
    private let authToken: String?

    // MARK: - Private state

    private var currentArtwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?

    /// References to the remote commands we registered targets on — used by
    /// `stop()` to detach via `removeTarget(nil)`.
    private var registeredCommands: [MPRemoteCommand] = []

    // MARK: - Lifecycle

    init(
        player: AVPlayer,
        video: Video,
        imageCache: ImageCache,
        seekInterval: Int,
        authToken: String? = nil,
        onPlay: @escaping () -> Void,
        onPause: @escaping () -> Void,
        onSeek: @escaping (TimeInterval) -> Void
    ) {
        self.player = player
        self.video = video
        self.imageCache = imageCache
        self.seekInterval = seekInterval
        self.authToken = authToken
        self.onPlay = onPlay
        self.onPause = onPause
        self.onSeek = onSeek
    }

    deinit {
        artworkTask?.cancel()
        // Safety net for abnormal teardown paths where the VM didn't call
        // `stop()` (e.g. VM deallocated without `stopPlayback()` running).
        // Without this, Control Center / lock screen would keep showing stale
        // metadata and remote-command targets would dangle, potentially
        // firing into a weak-self closure on a dealloc'd controller.
        //
        // Invariant — `registeredCommands` is the source of truth for
        // "are we currently published to Now Playing?":
        //   - After `start()` : non-empty (commands just registered).
        //   - After `stop()`  : empty (cleared as the last step of stop()).
        //   - Between init and start(): empty.
        // So `!registeredCommands.isEmpty` is equivalent to "start() ran and
        // stop() did not". A normal teardown path calls `stop()` first, hits
        // `deinit` with an empty array, and no-ops here — crucial to avoid
        // the race where an old controller's deferred deinit clobbers a new
        // controller's already-published metadata (e.g. user hits Back,
        // immediately taps Play on a different video, and the stale
        // controller's deinit runs on a later MainActor tick).
        //
        // `MPNowPlayingInfoCenter.default()` and `MPRemoteCommandCenter.shared()`
        // are thread-safe, so touching them from the nonisolated deinit is
        // fine even though the stored `registeredCommands` property itself
        // is MainActor-isolated.
        let commands = registeredCommands
        guard !commands.isEmpty else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        for command in commands {
            command.removeTarget(nil)
        }
    }

    // MARK: - Public API

    /// Registers remote command targets and publishes initial now-playing
    /// info (without artwork). Spawns a background task to load artwork via
    /// `ImageCache` and refreshes the info once available.
    func start() {
        setupRemoteCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = buildInfo(artwork: nil)

        // Load artwork asynchronously; refresh on completion.
        if let url = URL(string: video.thumbUrl) {
            let token = authToken
            let cache = imageCache
            artworkTask = Task { [weak self] in
                let image = await cache.image(for: url, token: token)
                guard let self, let image, !Task.isCancelled else { return }
                let size = image.size
                let artwork = MPMediaItemArtwork(boundsSize: size) { _ in image }
                self.currentArtwork = artwork
                self.refresh()
            }
        }
    }

    /// Rewrites the now-playing info dictionary with the latest elapsed time
    /// and playback rate. Safe to call repeatedly (e.g. from a 1s time
    /// observer) — it's just a dictionary assignment.
    func refresh() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = buildInfo(artwork: currentArtwork)
    }

    /// Clears now-playing info and removes all remote command targets.
    func stop() {
        artworkTask?.cancel()
        artworkTask = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        for command in registeredCommands {
            command.removeTarget(nil)
        }
        registeredCommands.removeAll()
    }

    // MARK: - Info dictionary

    /// Builds the Now Playing info dictionary. Exposed `internal` so tests
    /// can assert the shape without driving the full `start()` lifecycle.
    func buildInfo(artwork: MPMediaItemArtwork?) -> [String: Any] {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = video.title
        info[MPMediaItemPropertyArtist] = video.channelName
        info[MPMediaItemPropertyPlaybackDuration] = Double(video.duration)

        let elapsed: Double = {
            let seconds = player.currentTime().seconds
            return seconds.isFinite ? seconds : 0.0
        }()
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = Double(player.rate)
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue

        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        return info
    }

    // MARK: - Remote commands

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        // Play
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.onPlay()
            return .success
        }
        center.playCommand.isEnabled = true
        registeredCommands.append(center.playCommand)

        // Pause
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.onPause()
            return .success
        }
        center.pauseCommand.isEnabled = true
        registeredCommands.append(center.pauseCommand)

        // Toggle (headphone remote)
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.player.rate == 0 {
                self.onPlay()
            } else {
                self.onPause()
            }
            return .success
        }
        center.togglePlayPauseCommand.isEnabled = true
        registeredCommands.append(center.togglePlayPauseCommand)

        // Skip forward — clamp to `video.duration` so the lock-screen scrubber
        // doesn't display e.g. 310s on a 300s video. AVPlayer's own seek
        // clamps silently but the elapsed-time metadata we publish would
        // otherwise overshoot until the next refresh.
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: seekInterval)]
        center.skipForwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            let current = self.player.currentTime().seconds
            guard current.isFinite else { return .commandFailed }
            let target = min(current + Double(self.seekInterval), Double(self.video.duration))
            self.onSeek(target)
            return .success
        }
        center.skipForwardCommand.isEnabled = true
        registeredCommands.append(center.skipForwardCommand)

        // Skip backward — clamp to 0.
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: seekInterval)]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            let current = self.player.currentTime().seconds
            guard current.isFinite else { return .commandFailed }
            self.onSeek(max(0, current - Double(self.seekInterval)))
            return .success
        }
        center.skipBackwardCommand.isEnabled = true
        registeredCommands.append(center.skipBackwardCommand)

        // Change playback position (lock-screen scrubber)
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self else { return .commandFailed }
            guard let posEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self.onSeek(posEvent.positionTime)
            return .success
        }
        center.changePlaybackPositionCommand.isEnabled = true
        registeredCommands.append(center.changePlaybackPositionCommand)

        // We have no playlist semantics; disable ghost next/previous buttons
        // so iOS doesn't render them on the lock screen.
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }
}
