import Testing
import Foundation
import AVFoundation
import MediaPlayer
import UIKit
@testable import TAClient

/// Tests for A2 (Task 6): `NowPlayingController` publishes metadata to
/// `MPNowPlayingInfoCenter`, registers remote command targets, and disables
/// playlist-style commands (next/previous) we don't support.
///
/// Remote command invocation is validated via `isEnabled` flags and the
/// effect of `start()`/`stop()` on `nowPlayingInfo`. `MPRemoteCommand` does
/// not expose a public API to synthesize command events from tests, so we
/// assert state rather than handler return values — the handlers are
/// small, return explicit `.success`, and are exercised indirectly by the
/// VM integration tests in Task 7.
@MainActor
@Suite(.serialized) struct NowPlayingControllerTests {

    // MARK: - Helpers

    private func makeController(
        video: Video? = nil,
        seekInterval: Int = 10,
        onPlay: @escaping () -> Void = {},
        onPause: @escaping () -> Void = {},
        onSeek: @escaping (TimeInterval) -> Void = { _ in }
    ) -> NowPlayingController {
        let fixtureVideo = video ?? TestData.video(
            youtubeId: "vid-np-1",
            title: "Sample Title",
            duration: 300
        )
        return NowPlayingController(
            player: AVPlayer(),
            video: fixtureVideo,
            imageCache: ImageCache.shared,
            seekInterval: seekInterval,
            authToken: nil,
            onPlay: onPlay,
            onPause: onPause,
            onSeek: onSeek
        )
    }

    /// Reset global MediaPlayer singletons between tests so leftover state
    /// from one case doesn't cross-contaminate another.
    private func resetMediaPlayerGlobals() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        let center = MPRemoteCommandCenter.shared()
        let commands: [MPRemoteCommand] = [
            center.playCommand,
            center.pauseCommand,
            center.togglePlayPauseCommand,
            center.skipForwardCommand,
            center.skipBackwardCommand,
            center.changePlaybackPositionCommand,
            center.nextTrackCommand,
            center.previousTrackCommand
        ]
        for command in commands {
            command.removeTarget(nil)
        }
    }

    // MARK: - buildInfo

    @Test func buildInfo_containsRequiredFields() {
        resetMediaPlayerGlobals()

        let video = TestData.video(
            youtubeId: "vid-np-2",
            title: "My Title",
            duration: 420
        )
        let controller = makeController(video: video)

        let info = controller.buildInfo(artwork: nil)

        #expect(info[MPMediaItemPropertyTitle] as? String == "My Title")
        #expect(info[MPMediaItemPropertyArtist] as? String == video.channelName)
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? Double == 420)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 0)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        #expect(info[MPNowPlayingInfoPropertyMediaType] as? UInt == MPNowPlayingInfoMediaType.video.rawValue)
        #expect(info[MPMediaItemPropertyArtwork] == nil, "Artwork must be absent when nil passed")
    }

    @Test func buildInfo_includesArtworkWhenProvided() {
        resetMediaPlayerGlobals()

        let controller = makeController()
        let image = UIImage()
        let artwork = MPMediaItemArtwork(boundsSize: CGSize(width: 10, height: 10)) { _ in image }

        let info = controller.buildInfo(artwork: artwork)

        #expect(info[MPMediaItemPropertyArtwork] != nil, "Artwork must be present when supplied")
    }

    // MARK: - start / stop lifecycle

    @Test func startAndStop_populatesAndClearsNowPlayingInfo() async {
        resetMediaPlayerGlobals()

        let controller = makeController()
        controller.start()

        // Post-start: info center must be populated with the title we set.
        let afterStart = MPNowPlayingInfoCenter.default().nowPlayingInfo
        #expect(afterStart != nil, "nowPlayingInfo must be populated after start()")
        #expect(afterStart?[MPMediaItemPropertyTitle] as? String == "Sample Title")

        controller.stop()

        // Post-stop: info center must be cleared.
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo == nil, "nowPlayingInfo must be cleared after stop()")
    }

    @Test func refresh_rewritesNowPlayingInfo() {
        resetMediaPlayerGlobals()

        let controller = makeController()
        controller.start()

        // Wipe info directly; refresh() should repopulate.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        controller.refresh()

        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo != nil, "refresh() must rewrite nowPlayingInfo")

        controller.stop()
    }

    // MARK: - Remote command enablement

    @Test func setupRemoteCommands_enablesSupportedCommands() {
        resetMediaPlayerGlobals()

        let controller = makeController()
        controller.start()

        let center = MPRemoteCommandCenter.shared()
        #expect(center.playCommand.isEnabled == true, "playCommand must be enabled")
        #expect(center.pauseCommand.isEnabled == true, "pauseCommand must be enabled")
        #expect(center.togglePlayPauseCommand.isEnabled == true, "togglePlayPauseCommand must be enabled")
        #expect(center.skipForwardCommand.isEnabled == true, "skipForwardCommand must be enabled")
        #expect(center.skipBackwardCommand.isEnabled == true, "skipBackwardCommand must be enabled")
        #expect(center.changePlaybackPositionCommand.isEnabled == true, "changePlaybackPositionCommand must be enabled")

        controller.stop()
    }

    @Test func unusedCommands_areDisabled() {
        resetMediaPlayerGlobals()

        let controller = makeController()
        controller.start()

        let center = MPRemoteCommandCenter.shared()
        #expect(center.nextTrackCommand.isEnabled == false, "nextTrackCommand must be disabled (no playlist semantics)")
        #expect(center.previousTrackCommand.isEnabled == false, "previousTrackCommand must be disabled (no playlist semantics)")

        controller.stop()
    }

    @Test func skipCommands_advertisePreferredInterval() {
        resetMediaPlayerGlobals()

        let controller = makeController(seekInterval: 15)
        controller.start()

        let center = MPRemoteCommandCenter.shared()
        #expect(center.skipForwardCommand.preferredIntervals == [NSNumber(value: 15)],
                "skipForwardCommand must expose configured seek interval")
        #expect(center.skipBackwardCommand.preferredIntervals == [NSNumber(value: 15)],
                "skipBackwardCommand must expose configured seek interval")

        controller.stop()
    }

    @Test func stop_clearsEverything() {
        resetMediaPlayerGlobals()

        let controller = makeController()
        controller.start()

        // Sanity — some state must exist.
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo != nil)

        controller.stop()

        // After stop, repeated stop() is safe and state stays clear.
        controller.stop()
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo == nil)
    }
}
