import Foundation

@Observable
final class PlaylistListViewModel {
    var playlists: [Playlist] = []
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?
    var typeFilter: PlaylistTypeFilter = .all
    var showCreateDialog = false
    var newPlaylistName = ""

    private var currentPage = 1
    private var lastPage = 1
    private var canLoadMore: Bool { currentPage < lastPage && !isLoadingMore }

    let router: AppRouter
    private let playlistRepository: PlaylistRepositoryProtocol

    init(playlistRepository: PlaylistRepositoryProtocol, router: AppRouter) {
        self.playlistRepository = playlistRepository
        self.router = router
    }

    func loadPlaylists() async {
        isLoading = true
        errorMessage = nil
        currentPage = 1

        do {
            let result = try await playlistRepository.getPlaylists(page: 1, type: typeFilter.queryValue)
            playlists = result.playlists
            currentPage = result.currentPage
            lastPage = result.lastPage
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
            let result = try await playlistRepository.getPlaylists(page: nextPage, type: typeFilter.queryValue)
            let existingIds = Set(playlists.map(\.playlistId))
            playlists.append(contentsOf: result.playlists.filter { !existingIds.contains($0.playlistId) })
            currentPage = result.currentPage
            lastPage = result.lastPage
        } catch {
            router.handleError(error, errorMessage: &errorMessage)
        }

        isLoadingMore = false
    }

    func refresh() async {
        await loadPlaylists()
    }

    func onFilterChanged() {
        Task { await loadPlaylists() }
    }

    func createCustomPlaylist() async {
        let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        newPlaylistName = ""

        do {
            let playlist = try await playlistRepository.createCustomPlaylist(name: name)
            playlists.insert(playlist, at: 0)
        } catch {
            router.handleError(error, errorMessage: &errorMessage)
        }
    }

    func deletePlaylist(_ playlistId: String, deleteVideos: Bool) async {
        do {
            try await playlistRepository.deletePlaylist(id: playlistId, deleteVideos: deleteVideos)
            playlists.removeAll { $0.playlistId == playlistId }
        } catch {
            router.handleError(error, errorMessage: &errorMessage)
        }
    }

    func navigateToPlaylist(_ playlistId: String) {
        router.navigate(to: .playlistDetail(playlistId: playlistId))
    }
}

enum PlaylistTypeFilter: String, CaseIterable {
    case all
    case regular
    case custom

    var label: String {
        switch self {
        case .all: String(localized: "playlist_filter_all")
        case .regular: String(localized: "playlist_filter_regular")
        case .custom: String(localized: "playlist_filter_custom")
        }
    }

    var queryValue: String? {
        switch self {
        case .all: nil
        case .regular: "regular"
        case .custom: "custom"
        }
    }
}
