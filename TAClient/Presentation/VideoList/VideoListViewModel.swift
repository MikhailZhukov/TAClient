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
    var vidTypeFilter: VidTypeFilter = .all
    private(set) var refreshCount = 0

    var isSelecting = false
    var selectedVideoIds: Set<String> = []

    private var currentPage = 1
    private var lastPage = 1
    private var canLoadMore: Bool { currentPage < lastPage && !isLoadingMore }

    var hasActiveDownloads = false

    let router: AppRouter
    private let videoRepository: VideoRepositoryProtocol
    private let authRepository: AuthRepositoryProtocol
    private let downloadRepository: DownloadRepositoryProtocol

    init(videoRepository: VideoRepositoryProtocol, authRepository: AuthRepositoryProtocol, downloadRepository: DownloadRepositoryProtocol, router: AppRouter) {
        self.videoRepository = videoRepository
        self.authRepository = authRepository
        self.downloadRepository = downloadRepository
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
                channel: nil,
                vidType: vidTypeFilter.queryValue
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
                channel: nil,
                vidType: vidTypeFilter.queryValue
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

    func setVidType(_ type: VidTypeFilter) {
        guard type != vidTypeFilter else { return }
        vidTypeFilter = type
        Task { await loadVideos() }
    }

    func logout() {
        authRepository.logout()
        router.handleUnauthorized()
    }

    func toggleWatched(videoId: String) async {
        guard let index = videos.firstIndex(where: { $0.youtubeId == videoId }) else { return }
        let oldValue = videos[index].watched
        videos[index].watched = !oldValue

        do {
            try await videoRepository.setWatched(videoId: videoId, isWatched: !oldValue)
            removeIfFilterMismatch(videoId: videoId)
        } catch {
            if index < videos.count && videos[index].youtubeId == videoId {
                videos[index].watched = oldValue
            }
            router.handleError(error, errorMessage: &errorMessage)
        }
    }

    func applyWatchedChanges() {
        guard !router.watchedChanges.isEmpty else { return }
        for (videoId, isWatched) in router.watchedChanges {
            if let index = videos.firstIndex(where: { $0.youtubeId == videoId }) {
                videos[index].watched = isWatched
                removeIfFilterMismatch(videoId: videoId)
            }
        }
    }

    private func removeIfFilterMismatch(videoId: String) {
        guard let index = videos.firstIndex(where: { $0.youtubeId == videoId }) else { return }
        let watched = videos[index].watched
        let shouldRemove: Bool
        switch watchFilter {
        case .unwatched: shouldRemove = watched
        case .watched: shouldRemove = !watched
        case .continue: shouldRemove = watched
        case .all: shouldRemove = false
        }
        if shouldRemove {
            videos.remove(at: index)
        }
    }

    func removeDeletedVideos() {
        guard !router.deletedVideoIds.isEmpty else { return }
        videos.removeAll { router.deletedVideoIds.contains($0.youtubeId) }
    }

    func enterSelectionMode(videoId: String) {
        isSelecting = true
        selectedVideoIds = [videoId]
    }

    func toggleSelection(videoId: String) {
        if selectedVideoIds.contains(videoId) {
            selectedVideoIds.remove(videoId)
            if selectedVideoIds.isEmpty {
                isSelecting = false
            }
        } else {
            selectedVideoIds.insert(videoId)
        }
    }

    func cancelSelection() {
        isSelecting = false
        selectedVideoIds = []
    }

    func selectAll() {
        selectedVideoIds = Set(videos.map(\.youtubeId))
    }

    var showMarkWatched: Bool {
        switch watchFilter {
        case .all, .unwatched, .continue: return true
        case .watched: return false
        }
    }

    var showMarkUnwatched: Bool {
        switch watchFilter {
        case .all, .watched: return true
        case .unwatched, .continue: return false
        }
    }

    func batchSetWatched(_ isWatched: Bool) async {
        let ids = Array(selectedVideoIds)
        cancelSelection()

        for videoId in ids {
            guard let index = videos.firstIndex(where: { $0.youtubeId == videoId }) else { continue }
            videos[index].watched = isWatched

            do {
                try await videoRepository.setWatched(videoId: videoId, isWatched: isWatched)
                removeIfFilterMismatch(videoId: videoId)
            } catch {
                if let idx = videos.firstIndex(where: { $0.youtubeId == videoId }) {
                    videos[idx].watched = !isWatched
                }
                router.handleError(error, errorMessage: &errorMessage)
            }
        }
    }

    func batchDelete() async {
        let ids = Array(selectedVideoIds)
        cancelSelection()

        for videoId in ids {
            do {
                try await videoRepository.deleteVideo(id: videoId)
                videos.removeAll { $0.youtubeId == videoId }
                router.markVideoDeleted(videoId)
            } catch {
                router.handleError(error, errorMessage: &errorMessage)
            }
        }
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

    func navigateToPlaylists() {
        router.navigate(to: .playlistList)
    }

    func navigateToDownloadQueue() {
        router.navigate(to: .downloadQueue)
    }

    func navigateToSettings() {
        router.navigate(to: .settings)
    }

    func checkActiveDownloads() async {
        do {
            let notifications = try await downloadRepository.getNotifications()
            hasActiveDownloads = notifications.contains { $0.group.hasPrefix("download") }
        } catch {
            hasActiveDownloads = false
        }
    }
}
