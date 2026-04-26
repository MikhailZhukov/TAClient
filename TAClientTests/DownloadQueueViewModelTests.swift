import Foundation
import Testing
@testable import TAClient

struct DownloadQueueViewModelTests {

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

    @Test func loadDownloads_success_populatesItems() async {
        let repo = MockDownloadRepository()
        repo.getDownloadsHandler = { _, _ in
            TestData.downloadListResult(count: 3, currentPage: 1, lastPage: 2)
        }
        let (vm, _) = makeSUT(downloadRepo: repo)

        await vm.loadDownloads()

        #expect(vm.items.count == 3)
        #expect(vm.errorMessage == nil)
        #expect(vm.isLoading == false)
    }

    @Test func loadDownloads_unauthorized_routerHandles() async {
        let repo = MockDownloadRepository()
        repo.getDownloadsHandler = { _, _ in throw AppError.unauthorized }
        let (vm, router) = makeSUT(downloadRepo: repo)

        await vm.loadDownloads()

        #expect(router.appState == .login)
    }

    @Test func onFilterChanged_clearsAndReloads() async {
        let repo = MockDownloadRepository()
        var capturedFilter: String?
        repo.getDownloadsHandler = { _, filter in
            capturedFilter = filter
            return TestData.downloadListResult(count: 2)
        }
        let (vm, _) = makeSUT(downloadRepo: repo)

        vm.filter = "ignore"
        await vm.onFilterChanged()

        #expect(capturedFilter == "ignore")
        #expect(vm.items.count == 2)
    }

    @Test func updateStatus_optimisticallyRemovesItem() async {
        let repo = MockDownloadRepository()
        repo.getDownloadsHandler = { _, _ in
            TestData.downloadListResult(count: 3)
        }
        let (vm, _) = makeSUT(downloadRepo: repo)

        await vm.loadDownloads()
        #expect(vm.items.count == 3)

        let idToRemove = vm.items[0].youtubeId
        await vm.updateStatus(videoId: idToRemove, status: "ignore")

        #expect(vm.items.contains(where: { $0.youtubeId == idToRemove }) == false)
    }

    @Test func updateStatus_error_refetchesItems() async {
        let repo = MockDownloadRepository()
        repo.getDownloadsHandler = { _, _ in
            TestData.downloadListResult(count: 2)
        }
        repo.updateStatusHandler = { _, _ in
            throw AppError.serverError(statusCode: 500, message: "fail")
        }
        let (vm, _) = makeSUT(downloadRepo: repo)

        await vm.loadDownloads()
        #expect(vm.items.count == 2)
        let idToRemove = vm.items[0].youtubeId
        await vm.updateStatus(videoId: idToRemove, status: "ignore")

        // After error, items are refetched from server — all 2 items restored
        #expect(vm.items.count == 2)
        #expect(vm.items.contains(where: { $0.youtubeId == idToRemove }))
    }

    @Test func addToQueue_emptyInput_guards() async {
        var repoCalled = false
        let repo = MockDownloadRepository()
        repo.addToQueueHandler = { _ in repoCalled = true }
        let (vm, _) = makeSUT(downloadRepo: repo)

        vm.addInput = "   "
        await vm.addToQueue()

        #expect(repoCalled == false)
    }

    @Test func addToQueue_success_clearsInputAndReloads() async {
        let repo = MockDownloadRepository()
        repo.addToQueueHandler = { _ in }
        repo.getDownloadsHandler = { _, _ in
            TestData.downloadListResult(count: 1)
        }
        let (vm, _) = makeSUT(downloadRepo: repo)

        vm.addInput = "https://youtube.com/watch?v=abc123"
        await vm.addToQueue()

        #expect(vm.addInput == "")
        #expect(vm.isAdding == false)
    }

    @Test func deleteItem_optimisticallyRemovesItem() async {
        let repo = MockDownloadRepository()
        repo.getDownloadsHandler = { _, _ in
            TestData.downloadListResult(count: 3)
        }
        let (vm, _) = makeSUT(downloadRepo: repo)

        await vm.loadDownloads()
        #expect(vm.items.count == 3)

        let idToDelete = vm.items[1].youtubeId
        await vm.deleteItem(videoId: idToDelete)

        #expect(vm.items.contains(where: { $0.youtubeId == idToDelete }) == false)
    }
}
