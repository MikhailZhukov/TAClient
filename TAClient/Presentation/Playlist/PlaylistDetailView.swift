import SwiftUI

struct PlaylistDetailView: View {
    @Bindable var viewModel: PlaylistDetailViewModel

    var body: some View {
        Group {
            if viewModel.isLoading {
                LoadingView()
            } else if let error = viewModel.errorMessage {
                ErrorView(message: error) {
                    Task { await viewModel.loadPlaylist() }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        playlistHeader

                        AdaptiveVideoGrid(
                            videos: viewModel.videos,
                            onVideoTap: { videoId in
                                viewModel.navigateToVideo(videoId)
                            },
                            onChannelTap: { channelId in
                                viewModel.navigateToChannel(channelId)
                            },
                            onNearEnd: {
                                Task { await viewModel.loadMoreVideos() }
                            }
                        )

                        if viewModel.isLoadingMore {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding()
                        }
                    }
                }
                .geometryGroup()
            }
        }
        .navigationTitle(viewModel.playlist?.playlistName ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if viewModel.playlist != nil {
                    Button {
                        viewModel.showDeleteDialog = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel(String(localized: "playlist_delete"))
                }
            }
        }
        .confirmationDialog(
            String(localized: "playlist_delete_title"),
            isPresented: $viewModel.showDeleteDialog,
            titleVisibility: .visible
        ) {
            Button(String(localized: "playlist_delete_keep_videos"), role: .destructive) {
                Task { await viewModel.deletePlaylist(deleteVideos: false) }
            }
            Button(String(localized: "playlist_delete_with_videos"), role: .destructive) {
                Task { await viewModel.deletePlaylist(deleteVideos: true) }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "playlist_delete_message"))
        }
        .task {
            await viewModel.loadPlaylist()
        }
    }

    @ViewBuilder
    private var playlistHeader: some View {
        if let playlist = viewModel.playlist {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    AuthenticatedAsyncImage(url: playlist.playlistThumbnail)
                        .aspectRatio(16.0 / 9.0, contentMode: .fill)
                        .frame(width: 120)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(playlist.playlistName)
                            .font(.headline)

                        if !playlist.playlistChannel.isEmpty {
                            Button {
                                viewModel.navigateToChannel(playlist.playlistChannelId)
                            } label: {
                                Text(playlist.playlistChannel)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }

                        HStack(spacing: 8) {
                            Text(playlist.playlistType == .custom
                                 ? String(localized: "playlist_type_custom")
                                 : String(localized: "playlist_type_regular"))
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text(String(localized: "playlist_entry_count \(playlist.playlistEntries.count)"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal)

                if let description = playlist.playlistDescription, !description.isEmpty {
                    Text(description)
                        .font(.body)
                        .padding(.horizontal)
                }

                if playlist.playlistType == .regular {
                    HStack {
                        Spacer()
                        Button {
                            Task { await viewModel.toggleSubscription() }
                        } label: {
                            Text(playlist.playlistSubscribed
                                 ? String(localized: "playlist_unsubscribe")
                                 : String(localized: "playlist_subscribe"))
                                .font(.subheadline)
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(playlist.playlistSubscribed ? Color(.systemGray4) : .accentColor)
                        .accessibilityLabel(playlist.playlistSubscribed
                            ? String(localized: "playlist_unsubscribe")
                            : String(localized: "playlist_subscribe"))
                        Spacer()
                    }
                    .padding(.horizontal)
                }

                Divider()
            }
        }
    }
}
