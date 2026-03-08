import Foundation

@Observable
final class ChannelDetailViewModel {
    let channelId: String
    var channel: Channel?
    var videos: [Video] = []
    var isLoading = true
    var isLoadingMore = false
    var errorMessage: String?

    private var currentPage = 1
    private var lastPage = 1
    private var canLoadMore: Bool { currentPage < lastPage && !isLoadingMore }

    let router: AppRouter
    private let channelRepository: ChannelRepositoryProtocol
    private let videoRepository: VideoRepositoryProtocol

    init(channelId: String, channelRepository: ChannelRepositoryProtocol, videoRepository: VideoRepositoryProtocol, router: AppRouter) {
        self.channelId = channelId
        self.channelRepository = channelRepository
        self.videoRepository = videoRepository
        self.router = router
    }

    func loadChannel() async {
        isLoading = true
        errorMessage = nil

        do {
            async let channelTask = channelRepository.getChannel(id: channelId)
            async let videosTask = videoRepository.getVideos(
                page: 1, sort: "published", order: "desc", watch: nil, channel: channelId
            )

            let (loadedChannel, videoResult) = try await (channelTask, videosTask)
            channel = loadedChannel
            videos = videoResult.videos
            currentPage = videoResult.currentPage
            lastPage = videoResult.lastPage
        } catch {
            router.handleError(error, errorMessage: &errorMessage)
        }

        isLoading = false
    }

    func loadMoreVideos() async {
        guard canLoadMore else { return }
        isLoadingMore = true

        let nextPage = currentPage + 1
        do {
            let result = try await videoRepository.getVideos(
                page: nextPage, sort: "published", order: "desc", watch: nil, channel: channelId
            )
            let existingIds = Set(videos.map(\.youtubeId))
            videos.append(contentsOf: result.videos.filter { !existingIds.contains($0.youtubeId) })
            currentPage = result.currentPage
            lastPage = result.lastPage
        } catch {
            router.handleError(error, errorMessage: &errorMessage)
        }

        isLoadingMore = false
    }

    func removeDeletedVideos() {
        guard !router.deletedVideoIds.isEmpty else { return }
        videos.removeAll { router.deletedVideoIds.contains($0.youtubeId) }
    }

    func navigateToVideo(_ videoId: String) {
        router.navigate(to: .videoDetail(videoId: videoId))
    }
}
