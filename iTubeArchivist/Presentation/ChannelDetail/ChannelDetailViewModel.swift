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

    private let channelRepository: ChannelRepositoryProtocol
    private let videoRepository: VideoRepositoryProtocol
    private let router: AppRouter

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
        } catch let error as AppError {
            if case .unauthorized = error {
                router.handleUnauthorized()
            } else {
                errorMessage = error.errorDescription
            }
        } catch {
            errorMessage = String(localized: "error_generic")
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
            videos.append(contentsOf: result.videos)
            currentPage = result.currentPage
            lastPage = result.lastPage
        } catch let error as AppError {
            if case .unauthorized = error {
                router.handleUnauthorized()
            }
        } catch {}

        isLoadingMore = false
    }

    func navigateToVideo(_ videoId: String) {
        router.navigate(to: .videoDetail(videoId: videoId))
    }
}
