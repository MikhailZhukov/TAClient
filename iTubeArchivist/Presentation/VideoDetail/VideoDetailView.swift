import SwiftUI
import AVKit

struct VideoDetailView: View {
    @Bindable var viewModel: VideoDetailViewModel
    @State private var isPlaying = false
    @State private var player: AVPlayer?
    @State private var timeObserver: Any?

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
        .navigationTitle(viewModel.video?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    if isPlaying {
                        Button {
                            viewModel.isPinned.toggle()
                        } label: {
                            Image(systemName: viewModel.isPinned ? "pin.fill" : "pin")
                        }
                    }
                    Button {
                        viewModel.showDeleteDialog = true
                    } label: {
                        Image(systemName: "trash")
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
        .task {
            await viewModel.loadVideo()
        }
        .task {
            await viewModel.loadComments()
        }
        .onDisappear {
            saveAndCleanup()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func videoContent(_ video: Video) -> some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: viewModel.isPinned ? [.sectionHeaders] : []) {
                Section {
                    videoDetails(video)
                } header: {
                    playerArea(video)
                        .background(Color(uiColor: .systemBackground))
                }
            }
        }
    }

    // MARK: - Player

    @ViewBuilder
    private func playerArea(_ video: Video) -> some View {
        if isPlaying, let player {
            VideoPlayerView(player: player)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
        } else {
            ZStack {
                AuthenticatedAsyncImage(url: video.thumbUrl)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)

                Button {
                    startPlayback()
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
            }
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
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            if viewModel.selectedTab == 0 {
                if let description = video.description, !description.isEmpty {
                    Text(description)
                        .font(.body)
                        .padding(.horizontal)
                } else {
                    Text("-")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
            } else {
                CommentsSection(
                    comments: viewModel.comments,
                    isLoading: viewModel.isLoadingComments
                )
            }
        }
        .padding(.vertical)
    }

    // MARK: - Player Lifecycle

    private func startPlayback() {
        guard let asset = viewModel.playerAsset else { return }

        let playerItem = AVPlayerItem(asset: asset)
        let avPlayer = AVPlayer(playerItem: playerItem)

        if viewModel.startPosition > 0 {
            let time = CMTime(seconds: viewModel.startPosition, preferredTimescale: 600)
            avPlayer.seek(to: time)
        }

        let interval = CMTime(seconds: 10, preferredTimescale: 600)
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let seconds = time.seconds
            if seconds.isFinite && seconds > 0 {
                Task { await viewModel.saveProgress(position: seconds) }
            }
        }

        self.player = avPlayer
        isPlaying = true
        avPlayer.play()
    }

    private func saveAndCleanup() {
        guard let player else { return }
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
        let seconds = player.currentTime().seconds
        if seconds.isFinite && seconds > 0 {
            Task { await viewModel.saveProgress(position: seconds) }
        }
        player.pause()
        self.player = nil
    }
}
