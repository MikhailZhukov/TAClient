import SwiftUI
import AVKit

struct VideoDetailView: View {
    @Bindable var viewModel: VideoDetailViewModel

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
                    if viewModel.isPlaying {
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
            if !viewModel.isFullScreen {
                viewModel.stopPlayback()
            }
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
            VideoPlayerView(player: player, isFullScreen: $viewModel.isFullScreen)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
        } else {
            ZStack {
                AuthenticatedAsyncImage(url: video.thumbUrl)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)

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
}
