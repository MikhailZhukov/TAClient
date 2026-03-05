import SwiftUI

struct VideoListView: View {
    @State var viewModel: VideoListViewModel

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
                        SortFilterBar(
                            sortOption: $viewModel.sortOption,
                            sortAscending: $viewModel.sortAscending,
                            watchFilter: $viewModel.watchFilter
                        )

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
                    Button {
                        viewModel.navigateToDownloadQueue()
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }

                    Button {
                        viewModel.navigateToSearch()
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }

                    Button {
                        viewModel.logout()
                    } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                    }
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
    }
}
