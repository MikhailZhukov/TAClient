import Foundation

@Observable
final class VideoListViewModel {
    var videos: [Video] = []
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?

    var sortOption: SortOption = .downloaded
    var sortAscending: Bool = false
    var watchFilter: WatchFilter = .unwatched
    private(set) var refreshCount = 0

    private var currentPage = 1
    private var lastPage = 1
    private var canLoadMore: Bool { currentPage < lastPage && !isLoadingMore }

    let router: AppRouter
    private let videoRepository: VideoRepositoryProtocol
    private let authRepository: AuthRepositoryProtocol

    init(videoRepository: VideoRepositoryProtocol, authRepository: AuthRepositoryProtocol, router: AppRouter) {
        self.videoRepository = videoRepository
        self.authRepository = authRepository
        self.router = router
    }

    func loadVideos(isRefresh: Bool = false) async {
        if !isRefresh {
            isLoading = true
        }
        errorMessage = nil
        currentPage = 1

        do {
            let result = try await videoRepository.getVideos(
                page: 1,
                sort: sortOption.rawValue,
                order: sortAscending ? "asc" : "desc",
                watch: watchFilter.queryValue,
                channel: nil
            )
            videos = result.videos
            currentPage = result.currentPage
            lastPage = result.lastPage
            if isRefresh { refreshCount &+= 1 }
        } catch {
            router.handleError(error, errorMessage: &errorMessage)
        }

        isLoading = false
    }

    func loadMoreIfNeeded() async {
        guard canLoadMore else { return }
        isLoadingMore = true

        let nextPage = currentPage + 1
        do {
            let result = try await videoRepository.getVideos(
                page: nextPage,
                sort: sortOption.rawValue,
                order: sortAscending ? "asc" : "desc",
                watch: watchFilter.queryValue,
                channel: nil
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

    func refresh() async {
        await loadVideos(isRefresh: true)
    }

    func onSortOrFilterChanged() async {
        await loadVideos()
    }

    func logout() {
        authRepository.logout()
        router.handleUnauthorized()
    }

    func removeDeletedVideos() {
        guard !router.deletedVideoIds.isEmpty else { return }
        videos.removeAll { router.deletedVideoIds.contains($0.youtubeId) }
    }

    func navigateToVideo(_ videoId: String) {
        router.navigate(to: .videoDetail(videoId: videoId))
    }

    func navigateToSearch() {
        router.navigate(to: .search)
    }

    func navigateToChannel(_ channelId: String) {
        router.navigate(to: .channelDetail(channelId: channelId))
    }

    func navigateToDownloadQueue() {
        router.navigate(to: .downloadQueue)
    }
}
