import SwiftUI

struct SearchView: View {
    @Bindable var viewModel: SearchViewModel

    var body: some View {
        Group {
            if viewModel.isLoading {
                LoadingView()
            } else if viewModel.hasSearched && viewModel.videos.isEmpty {
                Text(String(localized: "search_empty"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.videos.isEmpty {
                Text(String(localized: "search_hint"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    AdaptiveVideoGrid(
                        videos: viewModel.videos,
                        onVideoTap: { videoId in
                            viewModel.navigateToVideo(videoId)
                        },
                        onChannelTap: { channelId in
                            viewModel.navigateToChannel(channelId)
                        }
                    )
                    .padding(.vertical)
                }
                .geometryGroup()
            }
        }
        .searchable(text: $viewModel.query, prompt: String(localized: "search_hint"))
        .onChange(of: viewModel.query) {
            viewModel.onQueryChanged()
        }
        .onChange(of: viewModel.router.deletedVideoIds) {
            viewModel.removeDeletedVideos()
        }
        .navigationTitle(String(localized: "video_list_search"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
