import SwiftUI

struct ChannelDetailView: View {
    @Bindable var viewModel: ChannelDetailViewModel
    @Environment(AuthState.self) private var authState
    @State private var showDeleteConfirmation = false

    var body: some View {
        Group {
            if viewModel.isLoading {
                LoadingView()
            } else if let error = viewModel.errorMessage {
                ErrorView(message: error) {
                    Task { await viewModel.loadChannel() }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        channelHeader

                        AdaptiveVideoGrid(
                            videos: viewModel.videos,
                            onVideoTap: { videoId in
                                viewModel.navigateToVideo(videoId)
                            },
                            onToggleWatched: { videoId in
                                Task { await viewModel.toggleWatched(videoId: videoId) }
                            },
                            onNearEnd: {
                                Task { await viewModel.loadMoreVideos() }
                            },
                            isSelecting: viewModel.isSelecting,
                            selectedIds: viewModel.selectedVideoIds,
                            onEnterSelection: { videoId in
                                viewModel.enterSelectionMode(videoId: videoId)
                            },
                            onToggleSelection: { videoId in
                                viewModel.toggleSelection(videoId: videoId)
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
        .navigationTitle(viewModel.channel?.channelName ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if viewModel.isSelecting {
                ToolbarItem(placement: .principal) {
                    Text(String(localized: "selection_count \(viewModel.selectedVideoIds.count)"))
                        .font(.headline)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            Task { await viewModel.batchSetWatched(true) }
                        } label: {
                            Image(systemName: "eye")
                        }
                        .accessibilityLabel(String(localized: "video_mark_watched"))

                        Button {
                            Task { await viewModel.batchSetWatched(false) }
                        } label: {
                            Image(systemName: "eye.slash")
                        }
                        .accessibilityLabel(String(localized: "video_mark_unwatched"))

                        if authState.isPrivileged {
                            Button {
                                showDeleteConfirmation = true
                            } label: {
                                Image(systemName: "trash")
                            }
                            .accessibilityLabel(String(localized: "selection_delete"))
                        }

                        Button {
                            viewModel.selectAll()
                        } label: {
                            Image(systemName: "checkmark.circle")
                        }
                        .accessibilityLabel(String(localized: "selection_select_all"))

                        Button(String(localized: "cancel")) {
                            viewModel.cancelSelection()
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            String(localized: "selection_delete_confirm \(viewModel.selectedVideoIds.count)"),
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "video_detail_delete"), role: .destructive) {
                Task { await viewModel.batchDelete() }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        }
        .task {
            await viewModel.loadChannel()
        }
        .onChange(of: viewModel.router.deletedVideoIds) {
            viewModel.removeDeletedVideos()
        }
        .onChange(of: viewModel.router.watchedChanges) {
            viewModel.applyWatchedChanges()
        }
    }

    @ViewBuilder
    private var channelHeader: some View {
        if let channel = viewModel.channel {
            VStack(alignment: .leading, spacing: 12) {
                // Banner
                if let bannerUrl = channel.channelBannerUrl {
                    AuthenticatedAsyncImage(url: bannerUrl)
                        .aspectRatio(6.2, contentMode: .fit)
                        .clipped()
                }

                HStack(spacing: 12) {
                    AuthenticatedAsyncImage(
                        url: channel.channelThumbUrl,
                        placeholderColor: Color(.tertiarySystemBackground)
                    )
                    .frame(width: 64, height: 64)
                    .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 4) {
                        Text(channel.channelName)
                            .font(.headline)
                        Text(String(localized: "channel_detail_subscribers \(channel.channelSubs)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if authState.isPrivileged {
                        Button {
                            Task { await viewModel.toggleSubscription() }
                        } label: {
                            Text(channel.channelSubscribed
                                 ? String(localized: "channel_unsubscribe")
                                 : String(localized: "channel_subscribe"))
                                .font(.subheadline)
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(channel.channelSubscribed ? Color(.systemGray4) : .accentColor)
                        .accessibilityLabel(channel.channelSubscribed
                            ? String(localized: "channel_unsubscribe")
                            : String(localized: "channel_subscribe"))
                    }
                }
                .padding(.horizontal)

                if let description = channel.channelDescription, !description.isEmpty {
                    Text(description)
                        .font(.body)
                        .padding(.horizontal)
                }

                Divider()
            }
        }
    }
}
