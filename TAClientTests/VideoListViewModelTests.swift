import SwiftUI
import Testing
@testable import TAClient

struct VideoListViewModelTests {

    private func makeSUT(
        videoRepo: MockVideoRepository = MockVideoRepository(),
        authRepo: MockAuthRepository = MockAuthRepository()
    ) -> (VideoListViewModel, AppRouter) {
        let keychain = KeychainService()
        keychain.clearAll()
        let authState = AuthState(keychainService: keychain)
        let router = AppRouter(authState: authState)
        let vm = VideoListViewModel(videoRepository: videoRepo, authRepository: authRepo, downloadRepository: MockDownloadRepository(), router: router)
        return (vm, router)
    }

    @Test func loadVideos_success_populatesVideos() async {
        let repo = MockVideoRepository()
        repo.getVideosHandler = { _, _, _, _, _, _ in
            TestData.videoListResult(count: 3, currentPage: 1, lastPage: 2)
        }
        let (vm, _) = makeSUT(videoRepo: repo)

        await vm.loadVideos()

        #expect(vm.videos.count == 3)
        #expect(vm.errorMessage == nil)
        #expect(vm.isLoading == false)
    }

    @Test func loadVideos_unauthorized_routerHandles() async {
        let repo = MockVideoRepository()
        repo.getVideosHandler = { _, _, _, _, _, _ in throw AppError.unauthorized }
        let (vm, router) = makeSUT(videoRepo: repo)

        await vm.loadVideos()

        #expect(router.appState == .login)
    }

    @Test func loadVideos_error_setsErrorMessage() async {
        let repo = MockVideoRepository()
        repo.getVideosHandler = { _, _, _, _, _, _ in
            throw AppError.serverError(statusCode: 500, message: "Internal Server Error")
        }
        let (vm, _) = makeSUT(videoRepo: repo)

        await vm.loadVideos()

        #expect(vm.errorMessage != nil)
        #expect(vm.isLoading == false)
    }

    @Test func loadMoreIfNeeded_atLastPage_doesNotCall() async {
        var callCount = 0
        let repo = MockVideoRepository()
        repo.getVideosHandler = { page, _, _, _, _, _ in
            callCount += 1
            return TestData.videoListResult(count: 3, currentPage: 1, lastPage: 1)
        }
        let (vm, _) = makeSUT(videoRepo: repo)

        await vm.loadVideos()
        let initialCount = callCount

        await vm.loadMoreIfNeeded()

        #expect(callCount == initialCount)
    }

    @Test func loadMoreIfNeeded_success_appendsVideos() async {
        let repo = MockVideoRepository()
        repo.getVideosHandler = { page, _, _, _, _, _ in
            if page == 1 {
                return TestData.videoListResult(count: 3, currentPage: 1, lastPage: 2)
            } else {
                return TestData.videoListResult(count: 2, startIndex: 3, currentPage: 2, lastPage: 2)
            }
        }
        let (vm, _) = makeSUT(videoRepo: repo)

        await vm.loadVideos()
        #expect(vm.videos.count == 3)

        await vm.loadMoreIfNeeded()
        #expect(vm.videos.count == 5)
    }

    @Test func refresh_incrementsRefreshCount() async {
        let repo = MockVideoRepository()
        repo.getVideosHandler = { _, _, _, _, _, _ in
            TestData.videoListResult(count: 1)
        }
        let (vm, _) = makeSUT(videoRepo: repo)

        let before = vm.refreshCount
        await vm.refresh()
        #expect(vm.refreshCount == before + 1)
    }

    @Test func logout_setsRouterToLogin() {
        let (vm, router) = makeSUT()
        vm.logout()
        #expect(router.appState == .login)
    }

    @Test func sortAndFilterParams_forwardedToRepo() async {
        var capturedSort: String?
        var capturedOrder: String?
        var capturedWatch: String?

        let repo = MockVideoRepository()
        repo.getVideosHandler = { _, sort, order, watch, _, _ in
            capturedSort = sort
            capturedOrder = order
            capturedWatch = watch
            return TestData.videoListResult()
        }
        let (vm, _) = makeSUT(videoRepo: repo)

        vm.sortOption = .published
        vm.sortAscending = true
        vm.watchFilter = .watched

        await vm.loadVideos()

        #expect(capturedSort == "published")
        #expect(capturedOrder == "asc")
        #expect(capturedWatch == "watched")
    }

    @Test func toggleWatched_unwatchedFilter_removesFromList() async {
        let repo = MockVideoRepository()
        repo.getVideosHandler = { _, _, _, _, _, _ in
            TestData.videoListResult(count: 3, currentPage: 1, lastPage: 1)
        }
        let (vm, _) = makeSUT(videoRepo: repo)
        vm.watchFilter = .unwatched

        await vm.loadVideos()
        #expect(vm.videos.count == 3)

        await vm.toggleWatched(videoId: "video-0")

        #expect(vm.videos.count == 2)
        #expect(!vm.videos.contains { $0.youtubeId == "video-0" })
    }

    @Test func toggleWatched_allFilter_keepsInList() async {
        let repo = MockVideoRepository()
        repo.getVideosHandler = { _, _, _, _, _, _ in
            TestData.videoListResult(count: 3, currentPage: 1, lastPage: 1)
        }
        let (vm, _) = makeSUT(videoRepo: repo)
        vm.watchFilter = .all

        await vm.loadVideos()
        await vm.toggleWatched(videoId: "video-0")

        #expect(vm.videos.count == 3)
        #expect(vm.videos[0].watched == true)
    }

    @Test func toggleWatched_error_revertsVideoInList() async {
        let repo = MockVideoRepository()
        repo.getVideosHandler = { _, _, _, _, _, _ in
            TestData.videoListResult(count: 3, currentPage: 1, lastPage: 1)
        }
        repo.setWatchedHandler = { _, _ in
            throw AppError.serverError(statusCode: 500, message: "Error")
        }
        let (vm, _) = makeSUT(videoRepo: repo)

        await vm.loadVideos()
        #expect(vm.videos[0].watched == false)

        await vm.toggleWatched(videoId: "video-0")

        #expect(vm.videos[0].watched == false)
        #expect(vm.errorMessage != nil)
    }

    @Test func enterSelectionMode_setsIsSelectingAndAddsId() {
        let (vm, _) = makeSUT()

        vm.enterSelectionMode(videoId: "vid-1")

        #expect(vm.isSelecting == true)
        #expect(vm.selectedVideoIds.contains("vid-1"))
    }

    @Test func toggleSelection_addsAndRemovesIds() {
        let (vm, _) = makeSUT()

        vm.enterSelectionMode(videoId: "vid-1")
        vm.toggleSelection(videoId: "vid-2")
        #expect(vm.selectedVideoIds.count == 2)

        vm.toggleSelection(videoId: "vid-1")
        #expect(vm.selectedVideoIds == ["vid-2"])

        vm.toggleSelection(videoId: "vid-2")
        #expect(vm.isSelecting == false)
        #expect(vm.selectedVideoIds.isEmpty)
    }

    @Test func cancelSelection_clearsState() {
        let (vm, _) = makeSUT()

        vm.enterSelectionMode(videoId: "vid-1")
        vm.toggleSelection(videoId: "vid-2")
        vm.cancelSelection()

        #expect(vm.isSelecting == false)
        #expect(vm.selectedVideoIds.isEmpty)
    }

    @Test func batchSetWatched_updatesVideosAndClearsSelection() async {
        let repo = MockVideoRepository()
        repo.getVideosHandler = { _, _, _, _, _, _ in
            TestData.videoListResult(count: 3, currentPage: 1, lastPage: 1)
        }
        let (vm, _) = makeSUT(videoRepo: repo)
        vm.watchFilter = .all

        await vm.loadVideos()
        vm.enterSelectionMode(videoId: "video-0")
        vm.toggleSelection(videoId: "video-1")

        await vm.batchSetWatched(true)

        #expect(vm.isSelecting == false)
        #expect(vm.selectedVideoIds.isEmpty)
        #expect(vm.videos[0].watched == true)
        #expect(vm.videos[1].watched == true)
        #expect(vm.videos[2].watched == false)
    }

    @Test func batchSetWatched_unwatchedFilter_removesFromList() async {
        let repo = MockVideoRepository()
        repo.getVideosHandler = { _, _, _, _, _, _ in
            TestData.videoListResult(count: 3, currentPage: 1, lastPage: 1)
        }
        let (vm, _) = makeSUT(videoRepo: repo)
        vm.watchFilter = .unwatched

        await vm.loadVideos()
        #expect(vm.videos.count == 3)

        vm.enterSelectionMode(videoId: "video-0")
        vm.toggleSelection(videoId: "video-1")

        await vm.batchSetWatched(true)

        #expect(vm.videos.count == 1)
        #expect(vm.videos[0].youtubeId == "video-2")
    }

    @Test func batchSetWatched_error_revertsAffectedVideo() async {
        let repo = MockVideoRepository()
        repo.getVideosHandler = { _, _, _, _, _, _ in
            TestData.videoListResult(count: 3, currentPage: 1, lastPage: 1)
        }
        repo.setWatchedHandler = { _, _ in
            throw AppError.serverError(statusCode: 500, message: "Error")
        }
        let (vm, _) = makeSUT(videoRepo: repo)
        vm.watchFilter = .all

        await vm.loadVideos()
        vm.enterSelectionMode(videoId: "video-0")

        await vm.batchSetWatched(true)

        #expect(vm.videos[0].watched == false)
        #expect(vm.errorMessage != nil)
    }

    @Test func navigation_appendsCorrectRoutes() {
        let (vm, router) = makeSUT()

        vm.navigateToVideo("vid-1")
        #expect(router.path.count == 1)

        vm.navigateToSearch()
        #expect(router.path.count == 2)

        vm.navigateToChannel("ch-1")
        #expect(router.path.count == 3)

        vm.navigateToDownloadQueue()
        #expect(router.path.count == 4)
    }
}
