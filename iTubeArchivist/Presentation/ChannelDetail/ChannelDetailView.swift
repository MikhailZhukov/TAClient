import SwiftUI

struct ChannelDetailView: View {
    @Bindable var viewModel: ChannelDetailViewModel

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
            }
        }
        .navigationTitle(viewModel.channel?.channelName ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadChannel()
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
                        placeholderColor: Color(hex: 0x3A3A3A)
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
