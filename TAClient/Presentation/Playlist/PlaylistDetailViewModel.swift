import Foundation

@Observable
final class PlaylistDetailViewModel {
    let playlistId: String
    var playlist: Playlist?
    var videos: [Video] = []
    var isLoading = true
    var isLoadingMore = false
    var errorMessage: String?
    var showDeleteDialog = false

    private var currentPage = 1
    private var lastPage = 1
    private var canLoadMore: Bool { currentPage < lastPage && !isLoadingMore }

    let router: AppRouter
    private let playlistRepository: PlaylistRepositoryProtocol
    private let videoRepository: VideoRepositoryProtocol

    init(playlistId: String, playlistRepository: PlaylistRepositoryProtocol, videoRepository: VideoRepositoryProtocol, router: AppRouter) {
        self.playlistId = playlistId
        self.playlistRepository = playlistRepository
        self.videoRepository = videoRepository
        self.router = router
    }

    func loadPlaylist() async {
        isLoading = true
        errorMessage = nil

        do {
            playlist = try await playlistRepository.getPlaylist(id: playlistId)
            let result = try await playlistRepository.getPlaylistVideos(playlistId: playlistId, page: 1)
            videos = result.videos
            currentPage = result.currentPage
            lastPage = result.lastPage
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
            let result = try await playlistRepository.getPlaylistVideos(playlistId: playlistId, page: nextPage)
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
        guard var updatedPlaylist = playlist else { return }
        let newValue = !updatedPlaylist.playlistSubscribed
        updatedPlaylist.playlistSubscribed = newValue
        playlist = updatedPlaylist

        do {
            try await playlistRepository.updateSubscription(playlistId: playlistId, subscribed: newValue)
        } catch {
            updatedPlaylist.playlistSubscribed = !newValue
            playlist = updatedPlaylist
            router.handleError(error, errorMessage: &errorMessage)
        }
    }

    func removeVideo(_ videoId: String) async {
        guard playlist?.playlistType == .custom else { return }
        let removed = videos.first { $0.youtubeId == videoId }
        videos.removeAll { $0.youtubeId == videoId }

        do {
            try await playlistRepository.removeVideoFromPlaylist(playlistId: playlistId, videoId: videoId)
        } catch {
            if let removed {
                videos.append(removed)
                videos.sort { $0.title < $1.title }
            }
            router.handleError(error, errorMessage: &errorMessage)
        }
    }

    func deletePlaylist(deleteVideos: Bool) async {
        do {
            try await playlistRepository.deletePlaylist(id: playlistId, deleteVideos: deleteVideos)
            router.goBack()
        } catch {
            router.handleError(error, errorMessage: &errorMessage)
        }
    }

    func navigateToVideo(_ videoId: String) {
        router.navigate(to: .videoDetail(videoId: videoId))
    }

    func navigateToChannel(_ channelId: String) {
        router.navigate(to: .channelDetail(channelId: channelId))
    }
}
