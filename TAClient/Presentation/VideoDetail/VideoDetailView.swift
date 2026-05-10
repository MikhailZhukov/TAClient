import SwiftUI
import AVKit
import OSLog

private nonisolated let viewLogger = Logger(subsystem: "ru.mzhukov.TAClient", category: "VideoDetailView")

struct VideoDetailView: View {
    @Bindable var viewModel: VideoDetailViewModel
    @Environment(AuthState.self) private var authState

    var body: some View {
        Group {
            if viewModel.isLoading {
                LoadingView()
            } else if let error = viewModel.errorMessage {
                ErrorView(message: error) {
                    Task { await viewModel.loadVideo() }
                }
            } else if let video = viewModel.video {
                videoContent(video)
            }
        }
        .geometryGroup()
        .navigationTitle(viewModel.video?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    if viewModel.isPlaying {
                        Button {
                            viewModel.isPinned.toggle()
                        } label: {
                            Image(systemName: viewModel.isPinned ? "pin.fill" : "pin")
                        }
                        .accessibilityLabel(String(localized: "video_detail_pin_player"))
                    }
                    if let video = viewModel.video {
                        Button {
                            Task { await viewModel.toggleWatched() }
                        } label: {
                            Image(systemName: video.watched ? "eye.fill" : "eye")
                        }
                        .accessibilityLabel(video.watched
                            ? String(localized: "video_mark_unwatched")
                            : String(localized: "video_mark_watched"))
                    }
                    Button {
                        viewModel.showAddToPlaylistSheet = true
                    } label: {
                        Image(systemName: "music.note.list")
                    }
                    .accessibilityLabel(String(localized: "video_add_to_playlist"))
                    if authState.isPrivileged {
                        Button {
                            viewModel.showDeleteDialog = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel(String(localized: "video_detail_delete_title"))
                    }
                }
            }
        }
        .confirmationDialog(
            String(localized: "video_detail_delete_title"),
            isPresented: $viewModel.showDeleteDialog,
            titleVisibility: .visible
        ) {
            Button(String(localized: "video_detail_delete_confirm"), role: .destructive) {
                Task { await viewModel.deleteVideo() }
            }
            Button(String(localized: "video_detail_delete_ignore"), role: .destructive) {
                Task { await viewModel.deleteAndIgnoreVideo() }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "video_detail_delete_message"))
        }
        .sheet(isPresented: $viewModel.showAddToPlaylistSheet) {
            AddToPlaylistSheet(viewModel: viewModel)
        }
        .task {
            await viewModel.loadVideo()
        }
        .task {
            await viewModel.loadComments()
        }
        .onAppear { viewModel.isViewVisible = true }
        .onDisappear {
            viewModel.isViewVisible = false
            if !viewModel.isFullScreen && !viewModel.isPiPActive {
                viewModel.stopPlayback()
            }
        }
        .onChange(of: viewModel.seekInterval) { _, _ in
            // Rebuild the now-playing controller so lock-screen skip buttons
            // advertise the new interval. Rare event, so the full rebuild cost
            // is acceptable.
            viewModel.seekIntervalDidChange()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func videoContent(_ video: Video) -> some View {
        if viewModel.isPinned {
            VStack(spacing: 0) {
                playerArea(video)
                ScrollView {
                    videoDetails(video)
                }
            }
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    playerArea(video)
                    videoDetails(video)
                }
            }
        }
    }

    // MARK: - Player

    @ViewBuilder
    private func playerArea(_ video: Video) -> some View {
        if let player = viewModel.player {
            ZStack {
                AVPlayerView(
                    player: player,
                    isFullScreen: $viewModel.isFullScreen,
                    isPiPActive: $viewModel.isPiPActive,
                    onPiPStopped: { viewModel.handlePiPStopped() },
                    onDoubleTap: viewModel.doubleTapToSeek ? { forward in
                        viewModel.seekByInterval(forward: forward)
                    } : nil
                )
                if viewModel.isBuffering {
                    Color.black
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }
                PlayerSeekFeedbackOverlay(
                    seekInterval: viewModel.seekInterval,
                    feedback: viewModel.seekFeedback
                )
                sponsorBlockBanner
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fill)
            .frame(maxWidth: .infinity)
            .clipped()
        } else if let vlcURL = viewModel.vlcMediaURL {
            ZStack {
                VLCPlayerView(
                    mediaURL: vlcURL,
                    startPosition: viewModel.startPosition,
                    duration: Double(video.duration),
                    onTimeChanged: { seconds in viewModel.onVLCTimeChanged(seconds: seconds) },
                    isFullScreen: $viewModel.isFullScreen,
                    sponsorBlockSeekTarget: viewModel.vlcSponsorBlockSeekTarget,
                    seekDelta: viewModel.vlcSeekDelta,
                    onSeekDeltaConsumed: { viewModel.clearVLCSeekDelta() },
                    onDoubleTap: viewModel.doubleTapToSeek ? { forward in
                        viewModel.seekByInterval(forward: forward)
                    } : nil
                )
                if viewModel.isBuffering {
                    Color.black
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }
                PlayerSeekFeedbackOverlay(
                    seekInterval: viewModel.seekInterval,
                    feedback: viewModel.seekFeedback
                )
                sponsorBlockBanner
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fill)
            .frame(maxWidth: .infinity)
            .clipped()
        } else {
            ZStack {
                AuthenticatedAsyncImage(url: video.thumbUrl)
                    .aspectRatio(16.0 / 9.0, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipped()

                if viewModel.isBuffering {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                } else {
                    Button {
                        viewModel.startPlayback()
                    } label: {
                        Circle()
                            .fill(.black.opacity(0.6))
                            .frame(width: 72, height: 72)
                            .overlay {
                                Image(systemName: "play.fill")
                                    .font(.title)
                                    .foregroundStyle(.white)
                            }
                    }
                    .accessibilityLabel(String(localized: "video_detail_play"))
                }

                if let playbackError = viewModel.playbackError {
                    VStack {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                            Text(playbackError)
                                .font(.caption)
                                .fontWeight(.medium)
                                .lineLimit(3)
                            Spacer()
                            Button {
                                viewModel.playbackError = nil
                                viewModel.startPlayback()
                            } label: {
                                Text(String(localized: "retry"))
                                    .font(.caption)
                                    .fontWeight(.bold)
                            }
                            .accessibilityLabel(String(localized: "retry"))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal, 8)
                        .padding(.top, 8)

                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.3), value: viewModel.playbackError)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
        }
    }

    // MARK: - SponsorBlock Banner

    @ViewBuilder
    private var sponsorBlockBanner: some View {
        if viewModel.showSkipBanner, let segment = viewModel.skippedSegment {
            VStack {
                HStack(spacing: 8) {
                    Image(systemName: "forward.fill")
                        .font(.caption)
                    Text(String(localized: "sponsorblock_skipped \(segment.category.label)"))
                        .font(.caption)
                        .fontWeight(.medium)
                    Spacer()
                    Button {
                        viewModel.undoSkip()
                    } label: {
                        Text(String(localized: "sponsorblock_undo"))
                            .font(.caption)
                            .fontWeight(.bold)
                    }
                    .accessibilityLabel(String(localized: "sponsorblock_undo"))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 8)
                .padding(.top, 8)

                Spacer()
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.3), value: viewModel.showSkipBanner)
        }
    }

    // MARK: - Details

    @ViewBuilder
    private func videoDetails(_ video: Video) -> some View {
        VStack(spacing: 16) {
            VideoInfoSection(video: video) { channelId in
                viewModel.navigateToChannel(channelId)
            }

            Picker("", selection: $viewModel.selectedTab) {
                Text(String(localized: "video_detail_description")).tag(0)
                Text(String(localized: "video_detail_comments")).tag(1)
                Text(String(localized: "video_detail_similar")).tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            switch viewModel.selectedTab {
            case 0:
                if let description = video.description, !description.isEmpty {
                    Text(description)
                        .font(.body)
                        .padding(.horizontal)
                } else {
                    Text("-")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
            case 2:
                SimilarVideosSection(
                    videos: viewModel.similarVideos,
                    isLoading: viewModel.isLoadingSimilar,
                    onVideoTap: { videoId in viewModel.navigateToVideo(videoId) },
                    onChannelTap: { channelId in viewModel.navigateToChannel(channelId) }
                )
                .task { await viewModel.loadSimilarVideos() }
            default:
                CommentsSection(
                    comments: viewModel.comments,
                    isLoading: viewModel.isLoadingComments
                )
            }
        }
        .padding(.vertical)
    }
}

// MARK: - AVPlayer Wrapper

struct AVPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    @Binding var isFullScreen: Bool
    @Binding var isPiPActive: Bool
    var onPiPStopped: (() -> Void)?
    var onDoubleTap: ((_ forward: Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(isFullScreen: $isFullScreen, isPiPActive: $isPiPActive, onPiPStopped: onPiPStopped, onDoubleTap: onDoubleTap)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.delegate = context.coordinator
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        Self.applyPlayerConfig(player)
        if let item = player.currentItem {
            context.coordinator.observeEnd(of: item, playerVC: controller)
        }
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        tap.numberOfTapsRequired = 2
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        controller.view.addGestureRecognizer(tap)
        context.coordinator.doubleTapRecognizer = tap
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.isFullScreen = $isFullScreen
        context.coordinator.isPiPActive = $isPiPActive
        context.coordinator.onPiPStopped = onPiPStopped
        context.coordinator.onDoubleTap = onDoubleTap
        context.coordinator.doubleTapRecognizer?.isEnabled = onDoubleTap != nil
        if controller.player !== player {
            controller.player = player
            Self.applyPlayerConfig(player)
            if let item = player.currentItem {
                context.coordinator.observeEnd(of: item, playerVC: controller)
            }
        }
    }

    /// Applies player-level config that must travel with the player on every
    /// swap. `audiovisualBackgroundPlaybackPolicy = .continuesIfPossible` is
    /// load-bearing for background audio (without it iOS suspends the app
    /// within ~5s when it goes to background); applying it only in
    /// `makeUIViewController` would silently regress when the underlying
    /// `AVPlayer` is replaced via `updateUIViewController`. Centralised here
    /// so both paths stay in sync.
    private static func applyPlayerConfig(_ player: AVPlayer) {
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
    }

    class Coordinator: NSObject, AVPlayerViewControllerDelegate, UIGestureRecognizerDelegate {
        var isFullScreen: Binding<Bool>
        var isPiPActive: Binding<Bool>
        var onPiPStopped: (() -> Void)?
        var onDoubleTap: ((_ forward: Bool) -> Void)?
        weak var doubleTapRecognizer: UITapGestureRecognizer?
        private var endObserver: Any?
        private var timeJumpObserver: Any?
        /// KVO on `AVPlayer.currentItem` so we self-rewire `endObserver` /
        /// `timeJumpObserver` when the VM swaps the item via
        /// `replaceCurrentItem(with:)` (e.g. AirPlay handoff). Without this,
        /// the per-item observers stay bound to the discarded item, the
        /// end-of-stream notification fires for an object no observer is
        /// listening to, and `didPlayToEnd` is silently never set on the new
        /// item — re-introducing the tail-replay bug after AirPlay swap.
        private var currentItemObserver: NSKeyValueObservation?
        private weak var playerVC: AVPlayerViewController?
        /// True once AVPlayerItemDidPlayToEndTime fires for the current item.
        /// Reset to false when a new item is observed in `observeEnd(of:playerVC:)`,
        /// and also when the user seeks the same item meaningfully back from end
        /// (e.g. taps the system Replay button — captured via `timeJumpedNotification`).
        /// Read by `shouldClampToEnd(...)` in the fullscreen-exit completion to override
        /// AVKit's internal seek-back-for-Replay drift at end-of-stream.
        ///
        /// Without the time-jump reset, this scenario would mis-clamp:
        /// 1. Video plays to end → `didPlayToEnd = true` and player pauses at duration.
        /// 2. User taps Replay → AVKit seeks to 0 and resumes; same `AVPlayerItem`,
        ///    so `observeEnd` is NOT called again.
        /// 3. User pauses mid-replay, exits fullscreen → status == .paused and
        ///    `didPlayToEnd` is still stale-true → predicate fires and
        ///    `seek(to: duration)` jumps the user to end-of-video.
        private var didPlayToEnd: Bool = false

        private static let nearEndWindow: Double = 0.5
        private static let endFlagClearThreshold: Double = 1.0
        private static let reclampDelay: TimeInterval = 0.15
        private static let reclampDriftTolerance: Double = 0.5

        init(isFullScreen: Binding<Bool>, isPiPActive: Binding<Bool>, onPiPStopped: (() -> Void)?, onDoubleTap: ((_ forward: Bool) -> Void)?) {
            self.isFullScreen = isFullScreen
            self.isPiPActive = isPiPActive
            self.onPiPStopped = onPiPStopped
            self.onDoubleTap = onDoubleTap
        }

        /// Decides whether to resume playback after fullscreen exit.
        ///
        /// Re-checks both `status` (which may have transitioned to .paused mid-animation
        /// when the item reached end-of-stream) and `currentTime` vs `duration` (belt-and-
        /// suspenders for the race where status hasn't yet transitioned but position is at
        /// end). Both checks must pass in addition to `wasPlaying`.
        ///
        /// `.waitingToPlayAtSpecifiedRate` is intentionally treated as "not playing" —
        /// matches the existing `wasPlaying = (status == .playing)` snapshot semantic.
        /// Do NOT change this to `status != .paused` — would silently regress.
        static func shouldResumePlayback(
            wasPlaying: Bool,
            status: AVPlayer.TimeControlStatus,
            currentTime: Double,
            duration: Double
        ) -> Bool {
            guard wasPlaying else { return false }
            guard status == .playing else { return false }
            let nearEnd = duration > 0 && currentTime >= duration - Self.nearEndWindow
            return !nearEnd
        }

        /// Decides whether to force-seek the player to exact duration after fullscreen exit.
        ///
        /// AVKit internally seeks the AVPlayerItem back ~3-7 seconds at end-of-stream to
        /// prepare its system "Replay" button. This is undocumented but reproducible.
        /// When fullscreen exits at the same moment, the player is left resting at the
        /// seeked-back position rather than at duration — visually showing a frame from
        /// 4-7 seconds before the actual end. This helper signals when the post-animation
        /// completion should re-seek to exact duration to override AVKit's seek-back.
        ///
        /// Uses `didPlayToEnd` (set by AVPlayerItemDidPlayToEndTime observer) rather than a
        /// position threshold because AVKit's seek-back may already have moved currentTime
        /// to duration-7s by the time this predicate is evaluated. The notification is
        /// the canonical end-of-stream signal.
        ///
        /// Mutually exclusive with `shouldResumePlayback`:
        /// - status == .playing → caller takes the resume path (legitimate mid-playback)
        /// - status == .paused AND didPlayToEnd → caller takes the clamp path (this helper)
        static func shouldClampToEnd(
            didPlayToEnd: Bool,
            duration: Double,
            status: AVPlayer.TimeControlStatus
        ) -> Bool {
            guard didPlayToEnd else { return false }
            guard duration.isFinite, duration > 0 else { return false }
            guard status == .paused else { return false }
            return true
        }

        /// Decides whether an `AVPlayerItem.timeJumpedNotification` should clear
        /// the stale `didPlayToEnd` flag. Distinguishes the two seek-back
        /// patterns that both fire `timeJumpedNotification` after end-of-stream:
        ///
        /// - User taps the system **Replay** button → AVKit seeks the same item
        ///   back to position ~0 and resumes. We MUST clear the flag, otherwise
        ///   the next pause-then-fullscreen-exit cycle would see stale-true
        ///   `didPlayToEnd` and mis-clamp the user back to duration.
        /// - AVKit's internal **seek-back-for-Replay** affordance (undocumented)
        ///   drifts position back ~3-7s from `duration` to a previous keyframe
        ///   so the system Replay button has somewhere to start from. We MUST
        ///   keep the flag set, since this is exactly the path
        ///   `shouldClampToEnd` exists to override.
        ///
        /// Production logs (2026-05-09 iPad capture) measured AVKit drift
        /// deltas of 4.22s and 7.54s. The Replay button always seeks to ~0.
        /// A near-zero threshold (`< 1.0s` from the start of the item) cleanly
        /// separates the two: the Replay path lands at 0; the AVKit drift path
        /// lands far from 0 on any video longer than ~10 seconds.
        ///
        /// Returns false for non-finite or non-positive `duration` (item not
        /// loaded / live stream / nonsensical) and for non-finite `currentTime`,
        /// matching the `shouldClampToEnd` defensive shape.
        static func shouldClearEndFlag(currentTime: Double, duration: Double) -> Bool {
            guard duration.isFinite, duration > 0, currentTime.isFinite else { return false }
            return currentTime < Self.endFlagClearThreshold
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let location = recognizer.location(in: view)
            let forward = location.x >= view.bounds.width / 2
            onDoubleTap?(forward)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        // INVARIANT: The Coordinator self-rewires its end / timeJumped observers
        // when `AVPlayer.currentItem` changes via KVO — so this is safe across
        // AirPlay-driven `replaceCurrentItem(with:)` swaps performed by
        // `VideoDetailViewModel.handleAirPlayBecameActive` and any future
        // mid-session item swaps on the same player. The KVO observation is
        // installed below (`currentItemObserver`) and torn down in `deinit`.
        // The codebase still defaults to one AVPlayer per video (per CLAUDE.md
        // "ViewModel lifecycle in NavigationStack"); the KVO is a defence-in-
        // depth measure for the AirPlay path and any future swap sites.
        func observeEnd(of playerItem: AVPlayerItem, playerVC: AVPlayerViewController) {
            self.playerVC = playerVC
            self.didPlayToEnd = false
            endObserver.map { NotificationCenter.default.removeObserver($0) }
            timeJumpObserver.map { NotificationCenter.default.removeObserver($0) }
            // Rebind the currentItem KVO every call so it tracks the latest
            // playerVC (callers may pass a different controller on later
            // invocations). Always invalidate before re-installing — otherwise
            // multiple KVOs would all fire on swap and re-invoke observeEnd
            // N times, leaking observer registrations.
            currentItemObserver?.invalidate()
            if let player = playerVC.player {
                currentItemObserver = player.observe(\.currentItem, options: [.new]) { [weak self, weak playerVC] _, change in
                    guard let self,
                          let playerVC,
                          let newItem = change.newValue ?? nil else { return }
                    // Re-entrancy: observeEnd will reset `didPlayToEnd`,
                    // re-bind `endObserver` / `timeJumpObserver` to `newItem`,
                    // and re-install this KVO. Safe — invalidation is the
                    // first step inside `observeEnd`.
                    self.observeEnd(of: newItem, playerVC: playerVC)
                }
            }
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: playerItem,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.didPlayToEnd = true
                if let vc = self.playerVC,
                   vc.presentedViewController != nil || vc.isBeingPresented {
                    vc.dismiss(animated: true)
                }
            }
            // Clear the stale-end-flag when the user seeks meaningfully back
            // from the end of the same item (e.g. system "Replay" button after
            // a natural play-to-end). Without this, a Replay-then-pause-then-
            // fullscreen-exit cycle would still see `didPlayToEnd == true` and
            // mis-clamp the user to duration.
            timeJumpObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.timeJumpedNotification,
                object: playerItem,
                queue: .main
            ) { [weak self, weak playerItem] _ in
                guard let self, let item = playerItem, self.didPlayToEnd else { return }
                let duration = item.duration.seconds
                let now = item.currentTime().seconds
                if Coordinator.shouldClearEndFlag(currentTime: now, duration: duration) {
                    self.didPlayToEnd = false
                }
            }
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            // TODO(v0.9.1 cleanup): remove with diagnostic instrumentation
            let t = playerViewController.player?.currentTime().seconds ?? -1
            let rate = playerViewController.player?.rate ?? 0
            viewLogger.notice("[Fullscreen] willBegin t=\(String(format: "%.2f", t))s rate=\(rate)")
            isFullScreen.wrappedValue = true
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            // TODO(v0.9.1 cleanup): remove with diagnostic instrumentation
            let wasPlaying = playerViewController.player?.timeControlStatus == .playing
            let t = playerViewController.player?.currentTime().seconds ?? -1
            let rate = playerViewController.player?.rate ?? 0
            viewLogger.notice("[Fullscreen] willEnd t=\(String(format: "%.2f", t))s rate=\(rate) wasPlaying=\(wasPlaying)")
            coordinator.animate(alongsideTransition: nil) { [self] _ in
                isFullScreen.wrappedValue = false
                let player = playerViewController.player
                let item = player?.currentItem
                let duration = item?.duration.seconds ?? 0
                let status = player?.timeControlStatus ?? .paused
                let currentTime = player?.currentTime().seconds ?? 0

                let shouldResume = Coordinator.shouldResumePlayback(
                    wasPlaying: wasPlaying,
                    status: status,
                    currentTime: currentTime,
                    duration: duration
                )
                let shouldClamp = Coordinator.shouldClampToEnd(
                    didPlayToEnd: didPlayToEnd,
                    duration: duration,
                    status: status
                )

                if shouldResume {
                    viewLogger.notice("[Fullscreen] resumePlay-after-exit")
                    player?.play()
                } else if shouldClamp, let itemDuration = item?.duration {
                    viewLogger.notice("[Fullscreen] clampToEnd-after-exit duration=\(String(format: "%.2f", duration))s")
                    player?.seek(to: itemDuration, toleranceBefore: .zero, toleranceAfter: .zero)
                    // Race mitigation: AVKit's internal seek-back may fire AFTER our seek.
                    // Re-clamp once after a short delay; cheap no-op if our first seek won.
                    DispatchQueue.main.asyncAfter(deadline: .now() + Coordinator.reclampDelay) { [weak player, weak item] in
                        guard let player, let item else { return }
                        // Defend against the AVPlayerItem being swapped out from
                        // under us during the 150ms delay (e.g. another video
                        // load races the dismissal). Seeking a stale item is
                        // a no-op at best, but seeking the *new* item to the
                        // *old* item's duration would be actively wrong.
                        guard player.currentItem === item else { return }
                        let duration2 = item.duration
                        // CMTime.zero is `.isNumeric == true`, so the original
                        // guard would let `seek(to: .zero)` through if duration
                        // collapsed to zero between the first seek and the
                        // re-clamp. Require a positive duration explicitly.
                        guard duration2.isNumeric, duration2.seconds > 0,
                              player.timeControlStatus == .paused else { return }
                        let now = player.currentTime()
                        let driftedAway = abs(now.seconds - duration2.seconds) > Coordinator.reclampDriftTolerance
                        if driftedAway {
                            player.seek(to: duration2, toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                    }
                }
            }
        }

        func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            isPiPActive.wrappedValue = true
        }

        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            onPiPStopped?()
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
        ) {
            completionHandler(true)
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            restoreUserInterfaceForFullScreenExitWithCompletionHandler completionHandler: @escaping (Bool) -> Void
        ) {
            completionHandler(true)
        }

        deinit {
            endObserver.map { NotificationCenter.default.removeObserver($0) }
            timeJumpObserver.map { NotificationCenter.default.removeObserver($0) }
            currentItemObserver?.invalidate()
        }
    }
}
