import Foundation
import SwiftUI
import Testing
@testable import TAClient

struct PlaylistListViewModelTests {

    private func makeSUT(
        playlistRepo: MockPlaylistRepository = MockPlaylistRepository()
    ) -> (PlaylistListViewModel, AppRouter) {
        let keychain = KeychainService()
        keychain.clearAll()
        let authState = AuthState(keychainService: keychain)
        let router = AppRouter(authState: authState)
        let vm = PlaylistListViewModel(playlistRepository: playlistRepo, router: router)
        return (vm, router)
    }

    @Test func loadPlaylists_success_populatesPlaylists() async {
        let repo = MockPlaylistRepository()
        repo.getPlaylistsHandler = { _, _ in TestData.playlistListResult(count: 3) }
        let (vm, _) = makeSUT(playlistRepo: repo)

        await vm.loadPlaylists()

        #expect(vm.playlists.count == 3)
        #expect(vm.errorMessage == nil)
        #expect(vm.isLoading == false)
    }

    @Test func loadPlaylists_error_setsErrorMessage() async {
        let repo = MockPlaylistRepository()
        repo.getPlaylistsHandler = { _, _ in throw AppError.serverError(statusCode: 500, message: "Error") }
        let (vm, _) = makeSUT(playlistRepo: repo)

        await vm.loadPlaylists()

        #expect(vm.errorMessage != nil)
        #expect(vm.isLoading == false)
    }

    @Test func loadPlaylists_unauthorized_routerHandles() async {
        let repo = MockPlaylistRepository()
        repo.getPlaylistsHandler = { _, _ in throw AppError.unauthorized }
        let (vm, router) = makeSUT(playlistRepo: repo)

        await vm.loadPlaylists()

        #expect(router.appState == .login)
    }

    @Test func loadMoreIfNeeded_appendsNewPlaylists() async {
        let repo = MockPlaylistRepository()
        var callCount = 0
        repo.getPlaylistsHandler = { page, _ in
            callCount += 1
            if page == 1 {
                return PlaylistListResult(
                    playlists: [TestData.playlist(playlistId: "pl-0")],
                    currentPage: 1, lastPage: 2
                )
            } else {
                return PlaylistListResult(
                    playlists: [TestData.playlist(playlistId: "pl-1")],
                    currentPage: 2, lastPage: 2
                )
            }
        }
        let (vm, _) = makeSUT(playlistRepo: repo)

        await vm.loadPlaylists()
        #expect(vm.playlists.count == 1)

        await vm.loadMoreIfNeeded()
        #expect(vm.playlists.count == 2)
        #expect(callCount == 2)
    }

    @Test func loadMoreIfNeeded_deduplicates() async {
        let repo = MockPlaylistRepository()
        repo.getPlaylistsHandler = { page, _ in
            PlaylistListResult(
                playlists: [TestData.playlist(playlistId: "pl-0")],
                currentPage: page, lastPage: 2
            )
        }
        let (vm, _) = makeSUT(playlistRepo: repo)

        await vm.loadPlaylists()
        await vm.loadMoreIfNeeded()

        #expect(vm.playlists.count == 1)
    }

    @Test func createCustomPlaylist_success_insertsAtTop() async {
        let repo = MockPlaylistRepository()
        repo.getPlaylistsHandler = { _, _ in TestData.playlistListResult(count: 2) }
        repo.createCustomPlaylistHandler = { name in
            TestData.playlist(playlistId: "new-pl", playlistName: name, playlistType: .custom)
        }
        let (vm, _) = makeSUT(playlistRepo: repo)

        await vm.loadPlaylists()
        #expect(vm.playlists.count == 2)

        vm.newPlaylistName = "  My New Playlist  "
        await vm.createCustomPlaylist()

        #expect(vm.playlists.count == 3)
        #expect(vm.playlists[0].playlistId == "new-pl")
        #expect(vm.playlists[0].playlistName == "My New Playlist")
        #expect(vm.newPlaylistName == "")
    }

    @Test func createCustomPlaylist_emptyName_doesNothing() async {
        var createCalled = false
        let repo = MockPlaylistRepository()
        repo.createCustomPlaylistHandler = { _ in
            createCalled = true
            return TestData.playlist()
        }
        let (vm, _) = makeSUT(playlistRepo: repo)

        vm.newPlaylistName = "   "
        await vm.createCustomPlaylist()

        #expect(!createCalled)
    }

    @Test func deletePlaylist_removesFromList() async {
        let repo = MockPlaylistRepository()
        repo.getPlaylistsHandler = { _, _ in TestData.playlistListResult(count: 3) }
        let (vm, _) = makeSUT(playlistRepo: repo)

        await vm.loadPlaylists()
        #expect(vm.playlists.count == 3)

        await vm.deletePlaylist("playlist-1", deleteVideos: false)

        #expect(vm.playlists.count == 2)
        #expect(!vm.playlists.contains { $0.playlistId == "playlist-1" })
    }

    @Test func deletePlaylist_error_showsError() async {
        let repo = MockPlaylistRepository()
        repo.getPlaylistsHandler = { _, _ in TestData.playlistListResult(count: 1) }
        repo.deletePlaylistHandler = { _, _ in throw AppError.serverError(statusCode: 500, message: "fail") }
        let (vm, _) = makeSUT(playlistRepo: repo)

        await vm.loadPlaylists()
        await vm.deletePlaylist("playlist-0", deleteVideos: false)

        #expect(vm.errorMessage != nil)
    }

    @Test func filterChange_passesTypeToRepo() async {
        var capturedType: String?
        let repo = MockPlaylistRepository()
        repo.getPlaylistsHandler = { _, type in
            capturedType = type
            return TestData.playlistListResult(count: 0)
        }
        let (vm, _) = makeSUT(playlistRepo: repo)

        vm.typeFilter = .custom
        await vm.loadPlaylists()

        #expect(capturedType == "custom")
    }

    @Test func navigation_appendsRoute() {
        let (vm, router) = makeSUT()
        vm.navigateToPlaylist("pl-1")
        #expect(router.path.count == 1)
    }
}

// MARK: - PlaylistDetailViewModel Tests

struct PlaylistDetailViewModelTests {

    private func makeSUT(
        playlistId: String = "test-playlist-id",
        playlistRepo: MockPlaylistRepository = MockPlaylistRepository(),
        videoRepo: MockVideoRepository = MockVideoRepository()
    ) -> (PlaylistDetailViewModel, AppRouter) {
        let keychain = KeychainService()
        keychain.clearAll()
        let authState = AuthState(keychainService: keychain)
        let router = AppRouter(authState: authState)
        let vm = PlaylistDetailViewModel(
            playlistId: playlistId,
            playlistRepository: playlistRepo,
            videoRepository: videoRepo,
            router: router
        )
        return (vm, router)
    }

    @Test func loadPlaylist_success_populatesData() async {
        let repo = MockPlaylistRepository()
        repo.getPlaylistHandler = { _ in TestData.playlist(playlistName: "My PL") }
        repo.getPlaylistVideosHandler = { _, _ in TestData.videoListResult(count: 5) }
        let (vm, _) = makeSUT(playlistRepo: repo)

        await vm.loadPlaylist()

        #expect(vm.playlist?.playlistName == "My PL")
        #expect(vm.videos.count == 5)
        #expect(vm.isLoading == false)
    }

    @Test func loadPlaylist_error_setsErrorMessage() async {
        let repo = MockPlaylistRepository()
        repo.getPlaylistHandler = { _ in throw AppError.serverError(statusCode: 404, message: "Not Found") }
        let (vm, _) = makeSUT(playlistRepo: repo)

        await vm.loadPlaylist()

        #expect(vm.errorMessage != nil)
        #expect(vm.isLoading == false)
    }

    @Test func toggleSubscription_success_updatesState() async {
        let repo = MockPlaylistRepository()
        repo.getPlaylistHandler = { _ in TestData.playlist(playlistSubscribed: true) }
        repo.getPlaylistVideosHandler = { _, _ in TestData.videoListResult(count: 0) }
        var capturedSubscribed: Bool?
        repo.updateSubscriptionHandler = { _, subscribed in capturedSubscribed = subscribed }
        let (vm, _) = makeSUT(playlistRepo: repo)

        await vm.loadPlaylist()
        #expect(vm.playlist?.playlistSubscribed == true)

        await vm.toggleSubscription()

        #expect(vm.playlist?.playlistSubscribed == false)
        #expect(capturedSubscribed == false)
    }

    @Test func toggleSubscription_error_revertsState() async {
        let repo = MockPlaylistRepository()
        repo.getPlaylistHandler = { _ in TestData.playlist(playlistSubscribed: false) }
        repo.getPlaylistVideosHandler = { _, _ in TestData.videoListResult(count: 0) }
        repo.updateSubscriptionHandler = { _, _ in throw AppError.serverError(statusCode: 500, message: "Error") }
        let (vm, _) = makeSUT(playlistRepo: repo)

        await vm.loadPlaylist()
        await vm.toggleSubscription()

        #expect(vm.playlist?.playlistSubscribed == false)
        #expect(vm.errorMessage != nil)
    }

    @Test func removeVideo_customPlaylist_removesFromList() async {
        let repo = MockPlaylistRepository()
        repo.getPlaylistHandler = { _ in TestData.playlist(playlistType: .custom) }
        repo.getPlaylistVideosHandler = { _, _ in TestData.videoListResult(count: 3) }
        let (vm, _) = makeSUT(playlistRepo: repo)

        await vm.loadPlaylist()
        #expect(vm.videos.count == 3)

        await vm.removeVideo("video-1")

        #expect(vm.videos.count == 2)
        #expect(!vm.videos.contains { $0.youtubeId == "video-1" })
    }

    @Test func removeVideo_regularPlaylist_doesNothing() async {
        let repo = MockPlaylistRepository()
        repo.getPlaylistHandler = { _ in TestData.playlist(playlistType: .regular) }
        repo.getPlaylistVideosHandler = { _, _ in TestData.videoListResult(count: 3) }
        let (vm, _) = makeSUT(playlistRepo: repo)

        await vm.loadPlaylist()
        await vm.removeVideo("video-1")

        #expect(vm.videos.count == 3)
    }

    @Test func removeVideo_error_revertsAndShowsError() async {
        let repo = MockPlaylistRepository()
        repo.getPlaylistHandler = { _ in TestData.playlist(playlistType: .custom) }
        repo.getPlaylistVideosHandler = { _, _ in TestData.videoListResult(count: 3) }
        repo.removeVideoFromPlaylistHandler = { _, _ in throw AppError.serverError(statusCode: 500, message: "fail") }
        let (vm, _) = makeSUT(playlistRepo: repo)

        await vm.loadPlaylist()
        await vm.removeVideo("video-0")

        #expect(vm.videos.count == 3)
        #expect(vm.errorMessage != nil)
    }

    @Test func deletePlaylist_success_goesBack() async {
        let repo = MockPlaylistRepository()
        repo.getPlaylistHandler = { _ in TestData.playlist() }
        repo.getPlaylistVideosHandler = { _, _ in TestData.videoListResult(count: 0) }
        let (vm, router) = makeSUT(playlistRepo: repo)

        router.navigate(to: .playlistDetail(playlistId: "test"))
        await vm.loadPlaylist()
        await vm.deletePlaylist(deleteVideos: false)

        #expect(router.path.isEmpty)
    }

    @Test func navigation_appendsRoutes() {
        let (vm, router) = makeSUT()

        vm.navigateToVideo("vid-1")
        #expect(router.path.count == 1)

        vm.navigateToChannel("ch-1")
        #expect(router.path.count == 2)
    }
}
