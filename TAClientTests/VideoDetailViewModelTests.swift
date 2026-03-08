import Foundation
import Testing
@testable import TAClient

struct VideoDetailViewModelTests {

    private func makeSUT(
        videoId: String = "test-video-id",
        videoRepo: MockVideoRepository = MockVideoRepository()
    ) -> (VideoDetailViewModel, AppRouter) {
        let keychain = KeychainService()
        keychain.clearAll()
        let authState = AuthState(keychainService: keychain)
        let router = AppRouter(authState: authState)
        let vm = VideoDetailViewModel(videoId: videoId, videoRepository: videoRepo, authState: authState, router: router)
        return (vm, router)
    }

    @Test func loadVideo_success_setsVideo() async {
        let repo = MockVideoRepository()
        let expectedVideo = TestData.video(youtubeId: "v1", title: "My Video")
        repo.getVideoHandler = { _ in expectedVideo }
        let (vm, _) = makeSUT(videoRepo: repo)

        await vm.loadVideo()

        #expect(vm.video?.youtubeId == "v1")
        #expect(vm.video?.title == "My Video")
        #expect(vm.isLoading == false)
        #expect(vm.errorMessage == nil)
    }

    @Test func loadVideo_unauthorized_routerHandles() async {
        let repo = MockVideoRepository()
        repo.getVideoHandler = { _ in throw AppError.unauthorized }
        let (vm, router) = makeSUT(videoRepo: repo)

        await vm.loadVideo()

        #expect(router.appState == .login)
    }

    @Test func loadVideo_error_setsErrorMessage() async {
        let repo = MockVideoRepository()
        repo.getVideoHandler = { _ in
            throw AppError.serverError(statusCode: 404, message: "Not Found")
        }
        let (vm, _) = makeSUT(videoRepo: repo)

        await vm.loadVideo()

        #expect(vm.errorMessage != nil)
        #expect(vm.isLoading == false)
    }

    @Test func loadComments_success_populatesComments() async {
        let repo = MockVideoRepository()
        repo.getCommentsHandler = { _ in
            [TestData.comment(id: "c1"), TestData.comment(id: "c2")]
        }
        let (vm, _) = makeSUT(videoRepo: repo)

        await vm.loadComments()

        #expect(vm.comments.count == 2)
        #expect(vm.isLoadingComments == false)
    }

    @Test func loadComments_failure_silentlyCaught() async {
        let repo = MockVideoRepository()
        repo.getCommentsHandler = { _ in
            throw AppError.network(underlying: nil)
        }
        let (vm, _) = makeSUT(videoRepo: repo)

        await vm.loadComments()

        #expect(vm.comments.isEmpty)
        #expect(vm.isLoadingComments == false)
    }

    @Test func saveProgress_callsRepo() async {
        var capturedVideoId: String?
        var capturedPosition: Double?
        let repo = MockVideoRepository()
        repo.updateProgressHandler = { videoId, position in
            capturedVideoId = videoId
            capturedPosition = position
        }
        let (vm, _) = makeSUT(videoId: "my-video", videoRepo: repo)

        await vm.saveProgress(position: 42.5)

        #expect(capturedVideoId == "my-video")
        #expect(capturedPosition == 42.5)
    }

    @Test func startPosition_returnsVideoPosition() async {
        let repo = MockVideoRepository()
        repo.getVideoHandler = { _ in TestData.video(position: 123.0) }
        let (vm, _) = makeSUT(videoRepo: repo)

        #expect(vm.startPosition == 0)

        await vm.loadVideo()
        #expect(vm.startPosition == 123.0)
    }
}
