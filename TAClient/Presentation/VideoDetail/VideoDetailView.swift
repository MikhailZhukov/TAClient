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
            if let item = player.currentItem {
                context.coordinator.observeEnd(of: item, playerVC: controller)
            }
        }
    }

    class Coordinator: NSObject, AVPlayerViewControllerDelegate, UIGestureRecognizerDelegate {
        var isFullScreen: Binding<Bool>
        var isPiPActive: Binding<Bool>
        var onPiPStopped: (() -> Void)?
        var onDoubleTap: ((_ forward: Bool) -> Void)?
        weak var doubleTapRecognizer: UITapGestureRecognizer?
        private var endObserver: Any?
        private weak var playerVC: AVPlayerViewController?

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
            let nearEnd = duration > 0 && currentTime >= duration - 0.5
            return !nearEnd
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

        func observeEnd(of playerItem: AVPlayerItem, playerVC: AVPlayerViewController) {
            self.playerVC = playerVC
            endObserver.map { NotificationCenter.default.removeObserver($0) }
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: playerItem,
                queue: .main
            ) { [weak self] _ in
                guard let self, let vc = self.playerVC else { return }
                if vc.presentedViewController != nil || vc.isBeingPresented {
                    vc.dismiss(animated: true)
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
                let shouldResume = Coordinator.shouldResumePlayback(
                    wasPlaying: wasPlaying,
                    status: player?.timeControlStatus ?? .paused,
                    currentTime: player?.currentTime().seconds ?? 0,
                    duration: player?.currentItem?.duration.seconds ?? 0
                )
                if shouldResume {
                    viewLogger.notice("[Fullscreen] resumePlay-after-exit")
                    player?.play()
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
        }
    }
}
