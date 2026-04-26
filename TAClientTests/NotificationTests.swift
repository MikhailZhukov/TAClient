import Foundation
import Testing
@testable import TAClient

struct NotificationBadgeTests {

    private func makeSUT(
        videoRepo: MockVideoRepository = MockVideoRepository(),
        downloadRepo: MockDownloadRepository = MockDownloadRepository()
    ) -> (VideoListViewModel, AppRouter) {
        let keychain = KeychainService()
        keychain.clearAll()
        let authState = AuthState(keychainService: keychain)
        let router = AppRouter(authState: authState)
        let vm = VideoListViewModel(
            videoRepository: videoRepo,
            authRepository: MockAuthRepository(),
            downloadRepository: downloadRepo,
            router: router
        )
        return (vm, router)
    }

    @Test func checkActiveDownloads_hasDownload_setsTrue() async {
        let downloadRepo = MockDownloadRepository()
        downloadRepo.getNotificationsHandler = {
            [TaskNotification(id: "t1", title: "Downloading", group: "download:run", messages: [], progress: 0.5, isError: false, canStop: true)]
        }
        let (vm, _) = makeSUT(downloadRepo: downloadRepo)

        await vm.checkActiveDownloads()

        #expect(vm.hasActiveDownloads == true)
    }

    @Test func checkActiveDownloads_noDownload_setsFalse() async {
        let downloadRepo = MockDownloadRepository()
        downloadRepo.getNotificationsHandler = {
            [TaskNotification(id: "t1", title: "Reindex", group: "reindex:run", messages: [], progress: 0.5, isError: false, canStop: false)]
        }
        let (vm, _) = makeSUT(downloadRepo: downloadRepo)

        await vm.checkActiveDownloads()

        #expect(vm.hasActiveDownloads == false)
    }

    @Test func checkActiveDownloads_empty_setsFalse() async {
        let downloadRepo = MockDownloadRepository()
        downloadRepo.getNotificationsHandler = { [] }
        let (vm, _) = makeSUT(downloadRepo: downloadRepo)

        await vm.checkActiveDownloads()

        #expect(vm.hasActiveDownloads == false)
    }

    @Test func checkActiveDownloads_error_setsFalse() async {
        let downloadRepo = MockDownloadRepository()
        downloadRepo.getNotificationsHandler = {
            throw AppError.network(underlying: nil)
        }
        let (vm, _) = makeSUT(downloadRepo: downloadRepo)

        await vm.checkActiveDownloads()

        #expect(vm.hasActiveDownloads == false)
    }
}

struct RescanEndpointTests {

    @Test func endpoint_path() {
        let endpoint = APIEndpoint.rescanSubscriptions
        #expect(endpoint.path.contains("/api/task/by-name/update_subscribed"))
    }

    @Test func endpoint_method_isPost() {
        let endpoint = APIEndpoint.rescanSubscriptions
        #expect(endpoint.method == .post)
    }
}

struct RescanViewModelTests {

    private func makeSUT(
        downloadRepo: MockDownloadRepository = MockDownloadRepository()
    ) -> (DownloadQueueViewModel, AppRouter) {
        let keychain = KeychainService()
        keychain.clearAll()
        let authState = AuthState(keychainService: keychain)
        let router = AppRouter(authState: authState)
        let vm = DownloadQueueViewModel(downloadRepository: downloadRepo, router: router)
        return (vm, router)
    }

    @Test func rescan_success_startsPolling() async {
        var rescanCalled = false
        let repo = MockDownloadRepository()
        repo.rescanSubscriptionsHandler = { rescanCalled = true }
        repo.getNotificationsHandler = { [] }
        let (vm, _) = makeSUT(downloadRepo: repo)

        await vm.rescanSubscriptions()

        #expect(rescanCalled)
        #expect(vm.isRescanningSubscriptions == false)
        vm.stopPolling()
    }

    @Test func rescan_error_showsError() async {
        let repo = MockDownloadRepository()
        repo.rescanSubscriptionsHandler = { throw AppError.serverError(statusCode: 500, message: "fail") }
        let (vm, _) = makeSUT(downloadRepo: repo)

        await vm.rescanSubscriptions()

        #expect(vm.errorMessage != nil)
        #expect(vm.isRescanningSubscriptions == false)
    }
}
