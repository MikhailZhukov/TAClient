import SwiftUI
import Testing
@testable import TAClient

struct ChannelDetailViewModelTests {

    private func makeSUT(
        channelId: String = "test-channel-id",
        channelRepo: MockChannelRepository = MockChannelRepository(),
        videoRepo: MockVideoRepository = MockVideoRepository()
    ) -> (ChannelDetailViewModel, AppRouter) {
        let keychain = KeychainService()
        keychain.clearAll()
        let authState = AuthState(keychainService: keychain)
        let router = AppRouter(authState: authState)
        let vm = ChannelDetailViewModel(
            channelId: channelId,
            channelRepository: channelRepo,
            videoRepository: videoRepo,
            router: router
        )
        return (vm, router)
    }

    @Test func loadChannel_success_setsChannelAndVideos() async {
        let channelRepo = MockChannelRepository()
        channelRepo.getChannelHandler = { _ in TestData.channel(channelName: "My Channel") }
        let videoRepo = MockVideoRepository()
        videoRepo.getVideosHandler = { _, _, _, _, _, _ in
            TestData.videoListResult(count: 3, currentPage: 1, lastPage: 2)
        }
        let (vm, _) = makeSUT(channelRepo: channelRepo, videoRepo: videoRepo)

        await vm.loadChannel()

        #expect(vm.channel?.channelName == "My Channel")
        #expect(vm.videos.count == 3)
        #expect(vm.isLoading == false)
        #expect(vm.errorMessage == nil)
    }

    @Test func loadChannel_unauthorized_routerHandles() async {
        let channelRepo = MockChannelRepository()
        channelRepo.getChannelHandler = { _ in throw AppError.unauthorized }
        let (vm, router) = makeSUT(channelRepo: channelRepo)

        await vm.loadChannel()

        #expect(router.appState == .login)
    }

    @Test func loadChannel_error_setsErrorMessage() async {
        let channelRepo = MockChannelRepository()
        channelRepo.getChannelHandler = { _ in
            throw AppError.serverError(statusCode: 500, message: "Server Error")
        }
        let (vm, _) = makeSUT(channelRepo: channelRepo)

        await vm.loadChannel()

        #expect(vm.errorMessage != nil)
        #expect(vm.isLoading == false)
    }

    @Test func loadMoreVideos_atLastPage_doesNotCall() async {
        var callCount = 0
        let videoRepo = MockVideoRepository()
        videoRepo.getVideosHandler = { page, _, _, _, _, _ in
            callCount += 1
            return TestData.videoListResult(count: 3, currentPage: 1, lastPage: 1)
        }
        let (vm, _) = makeSUT(videoRepo: videoRepo)

        await vm.loadChannel()
        let initialCount = callCount

        await vm.loadMoreVideos()

        #expect(callCount == initialCount)
    }

    @Test func loadMoreVideos_success_appendsVideos() async {
        let videoRepo = MockVideoRepository()
        videoRepo.getVideosHandler = { page, _, _, _, _, _ in
            if page == 1 {
                return TestData.videoListResult(count: 3, currentPage: 1, lastPage: 2)
            } else {
                return TestData.videoListResult(count: 2, startIndex: 3, currentPage: 2, lastPage: 2)
            }
        }
        let (vm, _) = makeSUT(videoRepo: videoRepo)

        await vm.loadChannel()
        #expect(vm.videos.count == 3)

        await vm.loadMoreVideos()
        #expect(vm.videos.count == 5)
    }

    @Test func toggleSubscription_success_updatesChannel() async {
        let channelRepo = MockChannelRepository()
        channelRepo.getChannelHandler = { _ in TestData.channel() }
        var capturedSubscribed: Bool?
        channelRepo.setSubscribedHandler = { _, subscribed in
            capturedSubscribed = subscribed
        }
        let (vm, _) = makeSUT(channelRepo: channelRepo)

        await vm.loadChannel()
        #expect(vm.channel?.channelSubscribed == true)

        await vm.toggleSubscription()

        #expect(vm.channel?.channelSubscribed == false)
        #expect(capturedSubscribed == false)
    }

    @Test func toggleSubscription_error_revertsState() async {
        let channelRepo = MockChannelRepository()
        channelRepo.getChannelHandler = { _ in TestData.channel() }
        channelRepo.setSubscribedHandler = { _, _ in
            throw AppError.serverError(statusCode: 500, message: "Server Error")
        }
        let (vm, _) = makeSUT(channelRepo: channelRepo)

        await vm.loadChannel()
        #expect(vm.channel?.channelSubscribed == true)

        await vm.toggleSubscription()

        #expect(vm.channel?.channelSubscribed == true)
        #expect(vm.errorMessage != nil)
    }

    @Test func batchSetWatched_updatesVideosAndNotifiesRouter() async {
        let videoRepo = MockVideoRepository()
        videoRepo.getVideosHandler = { _, _, _, _, _, _ in
            TestData.videoListResult(count: 3, currentPage: 1, lastPage: 1)
        }
        let (vm, router) = makeSUT(videoRepo: videoRepo)

        await vm.loadChannel()
        vm.enterSelectionMode(videoId: "video-0")
        vm.toggleSelection(videoId: "video-1")

        await vm.batchSetWatched(true)

        #expect(vm.isSelecting == false)
        #expect(vm.videos[0].watched == true)
        #expect(vm.videos[1].watched == true)
        #expect(vm.videos[2].watched == false)
        #expect(router.watchedChanges["video-0"] == true)
        #expect(router.watchedChanges["video-1"] == true)
    }

    @Test func navigation_appendsRoute() {
        let (vm, router) = makeSUT()
        vm.navigateToVideo("vid-1")
        #expect(router.path.count == 1)
    }
}
