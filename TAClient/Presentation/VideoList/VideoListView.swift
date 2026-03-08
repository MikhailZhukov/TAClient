import SwiftUI

struct VideoListView: View {
    @State var viewModel: VideoListViewModel
    @State private var showLogoutConfirmation = false

    var body: some View {
        @Bindable var viewModel = viewModel

        Group {
            if viewModel.isLoading && viewModel.videos.isEmpty {
                LoadingView()
            } else if let error = viewModel.errorMessage, viewModel.videos.isEmpty {
                ErrorView(message: error) {
                    Task { await viewModel.refresh() }
                }
            } else if viewModel.videos.isEmpty {
                Text(String(localized: "video_list_empty"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        AdaptiveVideoGrid(
                            videos: viewModel.videos,
                            onVideoTap: { videoId in
                                viewModel.navigateToVideo(videoId)
                            },
                            onChannelTap: { channelId in
                                viewModel.navigateToChannel(channelId)
                            },
                            onNearEnd: {
                                Task { await viewModel.loadMoreIfNeeded() }
                            }
                        )
                        .id(viewModel.refreshCount)

                        if viewModel.isLoadingMore {
                            ProgressView()
                                .padding()
                        }
                    }
                    .padding(.vertical)
                }
                .geometryGroup()
                .refreshable {
                    await viewModel.refresh()
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Text(String(localized: "video_list_title"))
                    .font(.title2)
                    .fontWeight(.bold)
                    .fixedSize()
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    SortFilterMenu(
                        sortOption: $viewModel.sortOption,
                        sortAscending: $viewModel.sortAscending,
                        watchFilter: $viewModel.watchFilter
                    )

                    Button {
                        viewModel.navigateToDownloadQueue()
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .accessibilityLabel(String(localized: "download_queue_title"))

                    Button {
                        viewModel.navigateToSearch()
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel(String(localized: "search_hint"))

                    Button {
                        showLogoutConfirmation = true
                    } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                    }
                    .accessibilityLabel(String(localized: "video_list_logout"))
                }
            }
        }
        .task {
            if viewModel.videos.isEmpty {
                await viewModel.loadVideos()
            }
        }
        .onChange(of: viewModel.sortOption) {
            Task { await viewModel.onSortOrFilterChanged() }
        }
        .onChange(of: viewModel.sortAscending) {
            Task { await viewModel.onSortOrFilterChanged() }
        }
        .onChange(of: viewModel.watchFilter) {
            Task { await viewModel.onSortOrFilterChanged() }
        }
        .onChange(of: viewModel.router.deletedVideoIds) {
            viewModel.removeDeletedVideos()
        }
        .confirmationDialog(
            String(localized: "video_list_logout"),
            isPresented: $showLogoutConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "video_list_logout"), role: .destructive) {
                viewModel.logout()
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        }
    }
}
