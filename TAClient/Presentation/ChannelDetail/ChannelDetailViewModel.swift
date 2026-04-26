import Foundation

@Observable
final class ChannelDetailViewModel {
    let channelId: String
    var channel: Channel?
    var videos: [Video] = []
    var isLoading = true
    var isLoadingMore = false
    var errorMessage: String?

    var isSelecting = false
    var selectedVideoIds: Set<String> = []

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
                page: 1, sort: "published", order: "desc", watch: nil, channel: channelId, vidType: nil
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
                page: nextPage, sort: "published", order: "desc", watch: nil, channel: channelId, vidType: nil
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

    func toggleSubscription() async {
        guard var updatedChannel = channel else { return }
        let newValue = !updatedChannel.channelSubscribed
        updatedChannel.channelSubscribed = newValue
        channel = updatedChannel

        do {
            try await channelRepository.setSubscribed(channelId: channelId, subscribed: newValue)
        } catch {
            updatedChannel.channelSubscribed = !newValue
            channel = updatedChannel
            router.handleError(error, errorMessage: &errorMessage)
        }
    }

    func toggleWatched(videoId: String) async {
        guard let index = videos.firstIndex(where: { $0.youtubeId == videoId }) else { return }
        let oldValue = videos[index].watched
        videos[index].watched = !oldValue

        do {
            try await videoRepository.setWatched(videoId: videoId, isWatched: !oldValue)
            router.markWatchedChanged(videoId, isWatched: !oldValue)
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
            }
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

    func batchSetWatched(_ isWatched: Bool) async {
        let ids = Array(selectedVideoIds)
        cancelSelection()

        for videoId in ids {
            guard let index = videos.firstIndex(where: { $0.youtubeId == videoId }) else { continue }
            videos[index].watched = isWatched

            do {
                try await videoRepository.setWatched(videoId: videoId, isWatched: isWatched)
                router.markWatchedChanged(videoId, isWatched: isWatched)
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
}
