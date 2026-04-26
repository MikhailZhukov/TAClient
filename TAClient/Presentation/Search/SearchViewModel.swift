import Foundation

@Observable
final class SearchViewModel {
    var query: String = ""
    var videos: [Video] = []
    var isLoading = false
    var hasSearched = false
    var errorMessage: String?

    let router: AppRouter
    private var searchTask: Task<Void, Never>?
    private let searchRepository: SearchRepositoryProtocol

    init(searchRepository: SearchRepositoryProtocol, router: AppRouter) {
        self.searchRepository = searchRepository
        self.router = router
    }

    func onQueryChanged() {
        searchTask?.cancel()

        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            videos = []
            hasSearched = false
            return
        }

        searchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return // cancelled
            }

            await performSearch()
        }
    }

    private func performSearch() async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }

        isLoading = true
        do {
            let result = try await searchRepository.search(query: trimmedQuery, page: 1)
            if !Task.isCancelled {
                videos = result.videos
                hasSearched = true
            }
        } catch {
            router.handleError(error, errorMessage: &errorMessage)
        }
        isLoading = false
    }

    func removeDeletedVideos() {
        guard !router.deletedVideoIds.isEmpty else { return }
        videos.removeAll { router.deletedVideoIds.contains($0.youtubeId) }
    }

    func navigateToVideo(_ videoId: String) {
        router.navigate(to: .videoDetail(videoId: videoId))
    }

    func navigateToChannel(_ channelId: String) {
        router.navigate(to: .channelDetail(channelId: channelId))
    }
}
