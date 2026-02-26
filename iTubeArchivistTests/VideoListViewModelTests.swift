import SwiftUI
import Testing
@testable import iTubeArchivist

struct VideoListViewModelTests {

    private func makeSUT(
        videoRepo: MockVideoRepository = MockVideoRepository(),
        authRepo: MockAuthRepository = MockAuthRepository()
    ) -> (VideoListViewModel, AppRouter) {
        let keychain = KeychainService()
        keychain.clearAll()
        let authState = AuthState(keychainService: keychain)
        let router = AppRouter(authState: authState)
        let vm = VideoListViewModel(videoRepository: videoRepo, authRepository: authRepo, router: router)
        return (vm, router)
    }

    @Test func loadVideos_success_populatesVideos() async {
        let repo = MockVideoRepository()
        repo.getVideosHandler = { _, _, _, _, _ in
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
        repo.getVideosHandler = { _, _, _, _, _ in throw AppError.unauthorized }
        let (vm, router) = makeSUT(videoRepo: repo)

        await vm.loadVideos()

        #expect(router.appState == .login)
    }

    @Test func loadVideos_error_setsErrorMessage() async {
        let repo = MockVideoRepository()
        repo.getVideosHandler = { _, _, _, _, _ in
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
        repo.getVideosHandler = { page, _, _, _, _ in
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
        repo.getVideosHandler = { page, _, _, _, _ in
            if page == 1 {
                return TestData.videoListResult(count: 3, currentPage: 1, lastPage: 2)
            } else {
                return TestData.videoListResult(count: 2, currentPage: 2, lastPage: 2)
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
        repo.getVideosHandler = { _, _, _, _, _ in
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
        repo.getVideosHandler = { _, sort, order, watch, _ in
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
