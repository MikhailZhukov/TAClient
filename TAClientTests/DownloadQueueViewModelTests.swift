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

    // MARK: - performPollTick (Task 1)

    @Test func performPollTick_finishTick_preservesLoadedPages_noCollapseToPageOne() async {
        let repo = MockDownloadRepository()
        // Per-page distinct items: page p -> ids dl-(p-1)*3 .. +3, lastPage 3.
        repo.getDownloadsHandler = { page, _ in
            TestData.downloadListResult(
                count: 3,
                startIndex: (page - 1) * 3,
                currentPage: page,
                lastPage: 3
            )
        }
        let (vm, _) = makeSUT(downloadRepo: repo)

        // Load up to currentPage == 3.
        await vm.loadDownloads()
        await vm.loadMoreIfNeeded()
        await vm.loadMoreIfNeeded()
        #expect(vm.items.count == 9)

        // Track which pages get fetched during the finish tick.
        var fetchedPages: [Int] = []
        repo.getDownloadsHandler = { page, _ in
            fetchedPages.append(page)
            return TestData.downloadListResult(
                count: 3,
                startIndex: (page - 1) * 3,
                currentPage: page,
                lastPage: 3
            )
        }
        // Finish: no active download.
        repo.getNotificationsHandler = { [] }

        let keepPolling = await vm.performPollTick()

        #expect(keepPolling == false)
        // All 3 loaded pages refetched (proves currentPage stayed 3, not collapsed to 1).
        #expect(Set(fetchedPages) == Set([1, 2, 3]))
        #expect(vm.items.count == 9)
    }

    @Test func performPollTick_completionTick_oneItemGone_removesOneAndKeepsPage() async {
        let repo = MockDownloadRepository()
        repo.getDownloadsHandler = { page, _ in
            TestData.downloadListResult(count: 3, currentPage: page, lastPage: 1)
        }
        let (vm, _) = makeSUT(downloadRepo: repo)

        await vm.loadDownloads()
        #expect(vm.items.count == 3)

        // Active download still in progress, but server now returns one fewer item.
        repo.getNotificationsHandler = {
            [TaskNotification(id: "t1", title: "Downloading", group: "download_pending",
                              messages: ["m"], progress: 0.5, isError: false, canStop: true)]
        }
        var fetchedPages: [Int] = []
        repo.getDownloadsHandler = { page, _ in
            fetchedPages.append(page)
            return TestData.downloadListResult(count: 2, currentPage: page, lastPage: 1)
        }

        let keepPolling = await vm.performPollTick()

        #expect(keepPolling == true) // active download -> keep polling
        #expect(vm.items.count == 2) // exactly one fewer
        #expect(fetchedPages == [1]) // currentPage preserved at 1, not reset/expanded
    }

    @Test func performPollTick_finishTick_onIgnoreTab_doesNotClobberWithPending() async {
        let repo = MockDownloadRepository()
        // Ignore-tab items use distinct ids so we can detect a pending clobber.
        repo.getDownloadsHandler = { _, filter in
            if filter == "ignore" {
                return DownloadListResult(
                    items: [
                        TestData.downloadItem(youtubeId: "ign-0", title: "Ignored 0", status: "ignore"),
                        TestData.downloadItem(youtubeId: "ign-1", title: "Ignored 1", status: "ignore")
                    ],
                    currentPage: 1,
                    lastPage: 1
                )
            }
            return TestData.downloadListResult(count: 5) // pending data that must NOT appear
        }
        let (vm, _) = makeSUT(downloadRepo: repo)

        vm.filter = "ignore"
        await vm.onFilterChanged()
        #expect(vm.items.count == 2)
        #expect(vm.items.allSatisfy { $0.youtubeId.hasPrefix("ign-") })

        // Finish tick while on the ignore tab.
        repo.getNotificationsHandler = { [] }
        let keepPolling = await vm.performPollTick()

        #expect(keepPolling == false)
        // items untouched — still the 2 ignore items, no pending data leaked in.
        #expect(vm.items.count == 2)
        #expect(vm.items.allSatisfy { $0.youtubeId.hasPrefix("ign-") })
    }

    // MARK: - performPollTick error paths (F1)

    @Test func performPollTick_finishTick_refetchThrows_keepsPollingAndItemsUnchanged() async {
        let repo = MockDownloadRepository()
        repo.getDownloadsHandler = { _, _ in
            TestData.downloadListResult(count: 3, currentPage: 1, lastPage: 1)
        }
        let (vm, _) = makeSUT(downloadRepo: repo)

        await vm.loadDownloads()
        #expect(vm.items.count == 3)
        let snapshot = vm.items

        // Finish tick (no active download) but the refetch throws a transient error.
        repo.getNotificationsHandler = { [] }
        repo.getDownloadsHandler = { _, _ in
            throw AppError.serverError(statusCode: 503, message: "transient")
        }

        let keepPolling = await vm.performPollTick()

        // Transient refetch failure -> keep polling, retry next tick; items untouched.
        #expect(keepPolling == true)
        #expect(vm.items == snapshot)
    }

    @Test func performPollTick_getNotificationsThrows_keepsPolling() async {
        let repo = MockDownloadRepository()
        repo.getDownloadsHandler = { _, _ in
            TestData.downloadListResult(count: 3, currentPage: 1, lastPage: 1)
        }
        let (vm, _) = makeSUT(downloadRepo: repo)

        await vm.loadDownloads()
        let snapshot = vm.items

        repo.getNotificationsHandler = {
            throw AppError.serverError(statusCode: 500, message: "transient")
        }

        let keepPolling = await vm.performPollTick()

        #expect(keepPolling == true)
        #expect(vm.items == snapshot)
    }

    // MARK: - currentPage clamp-down on lastPage shrink (F2)

    @Test func performPollTick_lastPageShrinks_clampsCurrentPage_nextTickFetchesFewerPages() async {
        let repo = MockDownloadRepository()
        repo.getDownloadsHandler = { page, _ in
            TestData.downloadListResult(
                count: 3, startIndex: (page - 1) * 3, currentPage: page, lastPage: 3
            )
        }
        let (vm, _) = makeSUT(downloadRepo: repo)

        // Load up to currentPage == 3.
        await vm.loadDownloads()
        await vm.loadMoreIfNeeded()
        await vm.loadMoreIfNeeded()
        #expect(vm.items.count == 9)

        // Active download; server now reports lastPage 2 (queue shrank).
        repo.getNotificationsHandler = {
            [TaskNotification(id: "t1", title: "Downloading", group: "download_pending",
                              messages: ["m"], progress: 0.5, isError: false, canStop: true)]
        }
        var fetchedPages: [Int] = []
        repo.getDownloadsHandler = { page, _ in
            fetchedPages.append(page)
            return TestData.downloadListResult(
                count: 3, startIndex: (page - 1) * 3, currentPage: page, lastPage: 2
            )
        }

        // First tick still fetches all 3 loaded pages, then clamps currentPage to 2.
        let keep1 = await vm.performPollTick()
        #expect(keep1 == true)
        #expect(Set(fetchedPages) == Set([1, 2, 3]))

        // Second tick fetches only pages 1-2 (currentPage was clamped).
        fetchedPages.removeAll()
        let keep2 = await vm.performPollTick()
        #expect(keep2 == true)
        #expect(Set(fetchedPages) == Set([1, 2]))
    }

    // MARK: - active-branch ignore-tab guard (F3)

    @Test func performPollTick_activeTick_onIgnoreTab_doesNotClobberWithPending() async {
        let repo = MockDownloadRepository()
        repo.getDownloadsHandler = { _, filter in
            if filter == "ignore" {
                return DownloadListResult(
                    items: [
                        TestData.downloadItem(youtubeId: "ign-0", title: "Ignored 0", status: "ignore"),
                        TestData.downloadItem(youtubeId: "ign-1", title: "Ignored 1", status: "ignore")
                    ],
                    currentPage: 1,
                    lastPage: 1
                )
            }
            return TestData.downloadListResult(count: 5) // pending data that must NOT appear
        }
        let (vm, _) = makeSUT(downloadRepo: repo)

        vm.filter = "ignore"
        await vm.onFilterChanged()
        #expect(vm.items.count == 2)

        // Active download while on the ignore tab.
        repo.getNotificationsHandler = {
            [TaskNotification(id: "t1", title: "Downloading", group: "download_pending",
                              messages: ["m"], progress: 0.5, isError: false, canStop: true)]
        }
        let keepPolling = await vm.performPollTick()

        #expect(keepPolling == true)
        // items untouched — still the 2 ignore items, no pending data leaked in.
        #expect(vm.items.count == 2)
        #expect(vm.items.allSatisfy { $0.youtubeId.hasPrefix("ign-") })
    }

    // MARK: - mid-await filter-switch race guard (finding 1)

    @Test func performPollTick_filterSwitchesMidFetch_dropsStalePendingData() async {
        let repo = MockDownloadRepository()
        repo.getDownloadsHandler = { _, _ in
            TestData.downloadListResult(count: 3, currentPage: 1, lastPage: 1)
        }
        let (vm, _) = makeSUT(downloadRepo: repo)

        await vm.loadDownloads()
        #expect(vm.items.count == 3)
        let snapshot = vm.items

        // Active download keeps polling alive. The pending refetch flips the filter to
        // "ignore" mid-fetch (simulating onFilterChanged firing during the await), then
        // returns pending data that must be dropped by the post-await re-check.
        repo.getNotificationsHandler = {
            [TaskNotification(id: "t1", title: "Downloading", group: "download_pending",
                              messages: ["m"], progress: 0.5, isError: false, canStop: true)]
        }
        repo.getDownloadsHandler = { _, _ in
            vm.filter = "ignore"
            return TestData.downloadListResult(count: 7) // pending data that must NOT be applied
        }

        let keepPolling = await vm.performPollTick()

        #expect(keepPolling == true)
        // Post-await filter re-check dropped the stale pending data; items unchanged.
        #expect(vm.items == snapshot)
    }

    // MARK: - loadMore-vs-reconcile depth race guard (finding 1)

    @Test func performPollTick_loadMoreAdvancesDepthMidFetch_doesNotDropNewPage() async {
        let repo = MockDownloadRepository()
        // lastPage 4, distinct ids per page so a dropped page is observable.
        repo.getDownloadsHandler = { page, _ in
            TestData.downloadListResult(
                count: 3, startIndex: (page - 1) * 3, currentPage: page, lastPage: 4
            )
        }
        let (vm, _) = makeSUT(downloadRepo: repo)

        // Loaded depth == 1 (currentPage 1, lastPage 4 -> more remains). The depth-1 path
        // takes `fetchAllLoadedPages`' single-fetch branch, giving one deterministic await
        // (no task-group concurrency) into which we inject the concurrent loadMore.
        await vm.loadDownloads()
        #expect(vm.items.count == 3)

        // Active download keeps polling alive.
        repo.getNotificationsHandler = {
            [TaskNotification(id: "t1", title: "Downloading", group: "download_pending",
                              messages: ["m"], progress: 0.5, isError: false, canStop: true)]
        }

        // Simulate the user scrolling (loadMoreIfNeeded) DURING the reconcile fetch await:
        // the page-1 fetch inside reconcile advances currentPage 1 -> 2 and appends page 2
        // BEFORE returning its (now shallow, depth-1) snapshot.
        var injectedLoadMore = false
        repo.getDownloadsHandler = { page, _ in
            if !injectedLoadMore {
                injectedLoadMore = true
                await vm.loadMoreIfNeeded() // advances depth 1 -> 2, appends page 2 (3 -> 6 items)
            }
            return TestData.downloadListResult(
                count: 3, startIndex: (page - 1) * 3, currentPage: page, lastPage: 4
            )
        }

        let keepPolling = await vm.performPollTick()

        #expect(keepPolling == true) // active download -> keep polling
        // The depth guard dropped the stale depth-1 snapshot: the just-loaded page 2 survives
        // (6 items, not clamped back to 3). The next tick reconciles at the new depth.
        #expect(vm.items.count == 6)
        #expect(vm.items.contains { $0.youtubeId == "dl-3" }) // a page-2 id survived
    }

    // MARK: - applyPolledItems (Task 2)

    @Test func applyPolledItems_identicalData_returnsFalse_shortCircuits() async {
        let repo = MockDownloadRepository()
        repo.getDownloadsHandler = { _, _ in
            TestData.downloadListResult(count: 3, currentPage: 1, lastPage: 1)
        }
        let (vm, _) = makeSUT(downloadRepo: repo)

        await vm.loadDownloads()
        #expect(vm.items.count == 3)
        let snapshot = vm.items

        // Same data as current items -> short-circuit, no reassignment.
        let changed = vm.applyPolledItems(snapshot)

        #expect(changed == false)
        #expect(vm.items == snapshot)
    }

    @Test func applyPolledItems_reorderedSameIds_returnsTrue_adoptsServerOrder() async {
        let repo = MockDownloadRepository()
        repo.getDownloadsHandler = { _, _ in
            TestData.downloadListResult(count: 3, currentPage: 1, lastPage: 1)
        }
        let (vm, _) = makeSUT(downloadRepo: repo)

        await vm.loadDownloads()
        #expect(vm.items.count == 3)
        let originalIds = vm.items.map(\.youtubeId)

        // Same id set, reversed order (e.g. an item reprioritized toward the top).
        let reordered = Array(vm.items.reversed())
        let changed = vm.applyPolledItems(reordered)

        #expect(changed == true)
        // Adopted the new server order.
        #expect(vm.items.map(\.youtubeId) == originalIds.reversed())
        // Same id set — reorder, not rebuild.
        #expect(Set(vm.items.map(\.youtubeId)) == Set(originalIds))
    }

    @Test func applyPolledItems_pendingRemovalFilteredOut_doesNotReappear() async {
        let repo = MockDownloadRepository()
        repo.getDownloadsHandler = { _, _ in
            TestData.downloadListResult(count: 3, currentPage: 1, lastPage: 1)
        }
        repo.deleteDownloadHandler = { _ in }
        let (vm, _) = makeSUT(downloadRepo: repo)

        await vm.loadDownloads()
        #expect(vm.items.count == 3)

        // Optimistic delete inserts the id into pendingRemovals.
        let removedId = vm.items[1].youtubeId
        await vm.deleteItem(videoId: removedId)
        #expect(vm.items.contains { $0.youtubeId == removedId } == false)

        // A subsequent poll that still includes the removed id must filter it out.
        // Filtered server result ([dl-0, dl-2]) equals current items, so it
        // short-circuits — but the removed id must NOT leak back in.
        let serverItems = TestData.downloadListResult(count: 3, currentPage: 1, lastPage: 1).items
        let changed = vm.applyPolledItems(serverItems)

        #expect(changed == false) // filtered result equals current items -> short-circuit
        #expect(vm.items.contains { $0.youtubeId == removedId } == false)
        #expect(vm.items.count == 2)
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
