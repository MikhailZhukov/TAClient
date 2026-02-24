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

    private var currentPage = 1
    private var lastPage = 1
    private var canLoadMore: Bool { currentPage < lastPage && !isLoadingMore }

    private let videoRepository: VideoRepositoryProtocol
    private let authRepository: AuthRepositoryProtocol
    private let router: AppRouter

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

    func navigateToVideo(_ videoId: String) {
        router.navigate(to: .videoDetail(videoId: videoId))
    }

    func navigateToSearch() {
        router.navigate(to: .search)
    }

    func navigateToChannel(_ channelId: String) {
        router.navigate(to: .channelDetail(channelId: channelId))
    }
}
