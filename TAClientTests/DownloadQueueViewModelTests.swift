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

    // MARK: - reloadPreservingDepth (Bug A — depth-preserving mutation reload)

    @Test func addToQueue_atDepth2_preservesLoadedPages_noCollapseToPageOne() async {
        let repo = MockDownloadRepository()
        repo.addToQueueHandler = { _ in }
        repo.getDownloadsHandler = { page, _ in
            TestData.downloadListResult(
                count: 3, startIndex: (page - 1) * 3, currentPage: page, lastPage: 3
            )
        }
        let (vm, _) = makeSUT(downloadRepo: repo)

        // Load to currentPage == 2.
        await vm.loadDownloads()
        await vm.loadMoreIfNeeded()
        #expect(vm.items.count == 6)

        // Track which pages the post-add reload fetches.
        var fetchedPages: [Int] = []
        repo.getDownloadsHandler = { page, _ in
            fetchedPages.append(page)
            return TestData.downloadListResult(
                count: 3, startIndex: (page - 1) * 3, currentPage: page, lastPage: 3
            )
        }

        vm.addInput = "https://youtube.com/watch?v=abc123"
        await vm.addToQueue()

        #expect(vm.addInput == "")
        // Both loaded pages refetched — proves currentPage stayed 2, NOT reset to 1.
        // (We assert reconciliation of the existing depth, not that a newly-added item
        // appears — a new item typically lands on a page beyond the loaded depth and is
        // intentionally not surfaced until the user scrolls; same as the old page-1 reload.)
        #expect(Set(fetchedPages) == Set([1, 2]))
        #expect(vm.items.count == 6)
    }

    @Test func stopCurrentDownload_atDepth2_preservesLoadedPages() async {
        let repo = MockDownloadRepository()
        repo.killTaskHandler = { _ in }
        repo.getDownloadsHandler = { page, _ in
            TestData.downloadListResult(
                count: 3, startIndex: (page - 1) * 3, currentPage: page, lastPage: 3
            )
        }
        let (vm, _) = makeSUT(downloadRepo: repo)

        await vm.loadDownloads()
        await vm.loadMoreIfNeeded()
        #expect(vm.items.count == 6)

        // A stoppable active task so stopCurrentDownload proceeds.
        vm.downloadProgress = [
            TaskNotification(id: "t1", title: "Downloading", group: "download_pending",
                             messages: ["m"], progress: 0.5, isError: false, canStop: true)
        ]

        var fetchedPages: [Int] = []
        repo.getDownloadsHandler = { page, _ in
            fetchedPages.append(page)
            return TestData.downloadListResult(
                count: 3, startIndex: (page - 1) * 3, currentPage: page, lastPage: 3
            )
        }

        await vm.stopCurrentDownload()

        #expect(vm.downloadProgress.isEmpty)
        #expect(Set(fetchedPages) == Set([1, 2])) // depth preserved, not collapsed to 1
        #expect(vm.items.count == 6)
    }

    @Test func deleteItem_error_onIgnoreTab_reloadsWithIgnoreFilter_revertsItem() async {
        let repo = MockDownloadRepository()
        repo.deleteDownloadHandler = { _ in
            throw AppError.serverError(statusCode: 500, message: "fail")
        }
        repo.getDownloadsHandler = { _, filter in
            // Distinct ids per tab so a pending clobber would be detectable.
            if filter == "ignore" {
                return DownloadListResult(
                    items: [
                        TestData.downloadItem(youtubeId: "ign-0", title: "Ignored 0", status: "ignore"),
                        TestData.downloadItem(youtubeId: "ign-1", title: "Ignored 1", status: "ignore")
                    ],
                    currentPage: 1, lastPage: 1
                )
            }
            return TestData.downloadListResult(count: 5) // pending data that must NOT leak in
        }
        let (vm, _) = makeSUT(downloadRepo: repo)

        vm.filter = "ignore"
        await vm.onFilterChanged()
        #expect(vm.items.count == 2)

        // Capture the filter the error-recovery reload uses.
        var reloadFilter: String?
        repo.getDownloadsHandler = { _, filter in
            reloadFilter = filter
            return DownloadListResult(
                items: [
                    TestData.downloadItem(youtubeId: "ign-0", title: "Ignored 0", status: "ignore"),
                    TestData.downloadItem(youtubeId: "ign-1", title: "Ignored 1", status: "ignore")
                ],
                currentPage: 1, lastPage: 1
            )
        }

        await vm.deleteItem(videoId: "ign-0")

        // Filter-aware: reload used the ignore tab, not hardcoded "pending".
        #expect(reloadFilter == "ignore")
        // Optimistic removal reverted, no pending data leaked.
        #expect(vm.items.count == 2)
        #expect(vm.items.allSatisfy { $0.youtubeId.hasPrefix("ign-") })
        #expect(vm.items.contains { $0.youtubeId == "ign-0" })
    }

    @Test func updateStatus_error_atDepth2_preservesLoadedPages_revertsItem() async {
        let repo = MockDownloadRepository()
        repo.updateStatusHandler = { _, _ in
            throw AppError.serverError(statusCode: 500, message: "fail")
        }
        repo.getDownloadsHandler = { page, _ in
            TestData.downloadListResult(
                count: 3, startIndex: (page - 1) * 3, currentPage: page, lastPage: 3
            )
        }
        let (vm, _) = makeSUT(downloadRepo: repo)

        await vm.loadDownloads()
        await vm.loadMoreIfNeeded()
        #expect(vm.items.count == 6)
        let idToRemove = vm.items[0].youtubeId

        var fetchedPages: [Int] = []
        repo.getDownloadsHandler = { page, _ in
            fetchedPages.append(page)
            return TestData.downloadListResult(
                count: 3, startIndex: (page - 1) * 3, currentPage: page, lastPage: 3
            )
        }

        await vm.updateStatus(videoId: idToRemove, status: "ignore")

        #expect(Set(fetchedPages) == Set([1, 2])) // depth preserved on error recovery
        #expect(vm.items.count == 6)
        #expect(vm.items.contains { $0.youtubeId == idToRemove }) // optimistic removal reverted
    }

    @Test func downloadItem_onIgnoreTab_removesMovedRow_surgically_withoutRefetch() async {
        let repo = MockDownloadRepository()
        var priorityCalledFor: String?
        repo.updateStatusHandler = { id, status in
            if status == "priority" { priorityCalledFor = id }
        }
        // Count getDownloads calls so we can prove the row leaves via an in-place removal,
        // NOT a full-array refetch (which would reset scroll + collide with the swipe).
        var getDownloadsCalls = 0
        repo.getDownloadsHandler = { _, _ in
            getDownloadsCalls += 1
            return DownloadListResult(
                items: ["ign-0", "ign-1"].map {
                    TestData.downloadItem(youtubeId: $0, title: $0, status: "ignore")
                },
                currentPage: 1, lastPage: 1
            )
        }
        let (vm, _) = makeSUT(downloadRepo: repo)

        vm.filter = "ignore"
        await vm.onFilterChanged() // 1 getDownloads call to load the ignore list
        #expect(vm.items.count == 2)
        let callsAfterLoad = getDownloadsCalls

        await vm.downloadItem(videoId: "ign-0")

        // The prioritised row is dropped immediately via a surgical in-place removal — no
        // manual refresh needed (polling reconcile is a no-op on the ignore tab).
        #expect(priorityCalledFor == "ign-0")
        #expect(vm.items.count == 1)
        #expect(vm.items.contains { $0.youtubeId == "ign-1" })
        #expect(vm.items.contains { $0.youtubeId == "ign-0" } == false)
        // No full-array reload happened — the removal was surgical (scroll/swipe-safe).
        #expect(getDownloadsCalls == callsAfterLoad)

        vm.stopPolling()
    }

    @Test func downloadItem_onPendingTab_keepsItemInPlace_noRemoval() async {
        let repo = MockDownloadRepository()
        var priorityCalled = false
        repo.updateStatusHandler = { _, status in
            if status == "priority" { priorityCalled = true }
        }
        repo.getDownloadsHandler = { _, _ in
            DownloadListResult(
                items: ["dl-0", "dl-1"].map {
                    TestData.downloadItem(youtubeId: $0, title: $0, status: "pending")
                },
                currentPage: 1, lastPage: 1
            )
        }
        let (vm, _) = makeSUT(downloadRepo: repo)

        await vm.loadDownloads() // filter defaults to "pending"
        #expect(vm.items.count == 2)

        await vm.downloadItem(videoId: "dl-0")

        // On the pending tab the prioritised item STAYS in the list (it is still pending) —
        // no optimistic removal, so nothing to jump. Reorder surfaces on the next poll tick.
        #expect(priorityCalled)
        #expect(vm.items.count == 2)
        #expect(vm.items.contains { $0.youtubeId == "dl-0" })

        vm.stopPolling()
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

        // Track which pages get fetched during the idle ticks.
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
        // Idle ticks: no active download, but the pending queue is NOT drained (9 items),
        // so the loop must survive the grace window, refetching all loaded pages each tick.
        repo.getNotificationsHandler = { [] }

        let bound = DownloadQueueViewModel.maxIdlePollsBeforeStop
        // First `bound - 1` idle ticks keep polling (grace), preserving the loaded depth.
        for _ in 0..<(bound - 1) {
            fetchedPages.removeAll()
            let keep = await vm.performPollTick()
            #expect(keep == true)
            // All 3 loaded pages refetched (proves currentPage stayed 3, not collapsed to 1).
            #expect(Set(fetchedPages) == Set([1, 2, 3]))
            #expect(vm.items.count == 9)
        }
        // The `bound`-th consecutive idle tick exhausts the grace window and stops.
        let keepFinal = await vm.performPollTick()
        #expect(keepFinal == false)
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

        // Idle ticks while on the ignore tab. `reconcileLoadedPages` is a no-op (pending
        // guard) and the fast-stop is skipped (filter != "pending"), so the grace window
        // governs the stop. Items must stay the 2 ignore items the whole time.
        repo.getNotificationsHandler = { [] }

        let bound = DownloadQueueViewModel.maxIdlePollsBeforeStop
        for _ in 0..<(bound - 1) {
            let keep = await vm.performPollTick()
            #expect(keep == true)
            #expect(vm.items.count == 2)
            #expect(vm.items.allSatisfy { $0.youtubeId.hasPrefix("ign-") })
        }
        let keepFinal = await vm.performPollTick()
        #expect(keepFinal == false)
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

    // MARK: - performPollTick grace + fast-stop (Bug B)

    @Test func performPollTick_singleIdleTick_withPendingItems_keepsPollingViaGrace() async {
        let repo = MockDownloadRepository()
        repo.getDownloadsHandler = { _, _ in
            TestData.downloadListResult(count: 3, currentPage: 1, lastPage: 1)
        }
        let (vm, _) = makeSUT(downloadRepo: repo)
        await vm.loadDownloads()
        #expect(vm.items.count == 3)

        // Idle tick (no active download) but pending queue is NOT drained.
        repo.getNotificationsHandler = { [] }
        let keep = await vm.performPollTick()

        // A single idle tick must NOT stop — it's likely a between-videos gap.
        #expect(keep == true)
        #expect(vm.items.count == 3)
    }

    @Test func performPollTick_graceExhausted_stopsAfterMaxIdlePolls() async {
        let repo = MockDownloadRepository()
        repo.getDownloadsHandler = { _, _ in
            TestData.downloadListResult(count: 3, currentPage: 1, lastPage: 1)
        }
        let (vm, _) = makeSUT(downloadRepo: repo)
        await vm.loadDownloads()

        repo.getNotificationsHandler = { [] }
        let bound = DownloadQueueViewModel.maxIdlePollsBeforeStop

        // First `bound - 1` idle ticks keep polling (queue non-empty, within grace).
        for _ in 0..<(bound - 1) {
            #expect(await vm.performPollTick() == true)
        }
        // The `bound`-th consecutive idle tick exhausts the grace window.
        #expect(await vm.performPollTick() == false)
    }

    @Test func performPollTick_idleThenActive_resetsGraceCounter() async {
        let repo = MockDownloadRepository()
        repo.getDownloadsHandler = { _, _ in
            TestData.downloadListResult(count: 3, currentPage: 1, lastPage: 1)
        }
        let (vm, _) = makeSUT(downloadRepo: repo)
        await vm.loadDownloads()

        let bound = DownloadQueueViewModel.maxIdlePollsBeforeStop
        let active = [
            TaskNotification(id: "t1", title: "Downloading", group: "download_pending",
                             messages: ["m"], progress: 0.5, isError: false, canStop: true)
        ]

        // Walk the idle counter to `bound - 1` (one short of stopping).
        repo.getNotificationsHandler = { [] }
        for _ in 0..<(bound - 1) {
            #expect(await vm.performPollTick() == true)
        }

        // An active tick must reset the counter.
        repo.getNotificationsHandler = { active }
        #expect(await vm.performPollTick() == true)

        // Now `bound - 1` more idle ticks should ALL keep polling — proving the counter
        // restarted from zero rather than carrying over and stopping early.
        repo.getNotificationsHandler = { [] }
        for _ in 0..<(bound - 1) {
            #expect(await vm.performPollTick() == true)
        }
    }

    @Test func performPollTick_idleTick_drainedQueue_fastStops() async {
        let repo = MockDownloadRepository()
        repo.getDownloadsHandler = { _, _ in
            TestData.downloadListResult(count: 3, currentPage: 1, lastPage: 1)
        }
        let (vm, _) = makeSUT(downloadRepo: repo)
        await vm.loadDownloads()
        #expect(vm.items.count == 3)

        // Idle tick AND the server now reports an empty pending queue (fully drained).
        repo.getNotificationsHandler = { [] }
        repo.getDownloadsHandler = { _, _ in
            TestData.downloadListResult(count: 0, currentPage: 1, lastPage: 1)
        }

        // Fast-stop fires on the FIRST idle tick — no need to burn the grace window.
        let keep = await vm.performPollTick()
        #expect(keep == false)
        #expect(vm.items.isEmpty)
    }

    @Test func performPollTick_withinGrace_emptyNotifications_keepsBanner() async {
        let repo = MockDownloadRepository()
        repo.getDownloadsHandler = { _, _ in
            TestData.downloadListResult(count: 3, currentPage: 1, lastPage: 1)
        }
        let (vm, _) = makeSUT(downloadRepo: repo)
        await vm.loadDownloads()

        // Simulate a banner left over from the previous (active) tick.
        vm.downloadProgress = [
            TaskNotification(id: "t1", title: "Downloading", group: "download_pending",
                             messages: ["m"], progress: 0.7, isError: false, canStop: true)
        ]

        // Idle tick with empty notifications, queue not drained -> within grace.
        repo.getNotificationsHandler = { [] }
        let keep = await vm.performPollTick()

        #expect(keep == true)
        // Banner preserved (not blanked to empty) so it doesn't flicker between videos.
        #expect(vm.downloadProgress.count == 1)
        #expect(vm.downloadProgress.first?.id == "t1")
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

    @Test func performPollTick_lastPageZeroOnFinalPage_doesNotCollapseDepth() async {
        // Regression: TA reports `last_page: 0` on the FINAL loaded page. The repo neutralises
        // this, but the VM must ALSO be robust — a non-positive `newLastPage` reaching reconcile
        // (via the final page's result) must NOT clamp `currentPage` to 0, which would make the
        // next `fetchAllLoadedPages(upTo: 0)` refetch only page 1 and collapse a deep list to the
        // top (the exact production log: items 178 -> 12).
        let repo = MockDownloadRepository()
        repo.getDownloadsHandler = { page, _ in
            // Final loaded page (3) reports the bogus last_page 0; earlier pages report 3.
            let last = page >= 3 ? 0 : 3
            return TestData.downloadListResult(
                count: 3, startIndex: (page - 1) * 3, currentPage: page, lastPage: last
            )
        }
        let (vm, _) = makeSUT(downloadRepo: repo)

        await vm.loadDownloads()
        await vm.loadMoreIfNeeded()
        await vm.loadMoreIfNeeded() // currentPage == 3, final page reports lastPage 0
        #expect(vm.items.count == 9)

        repo.getNotificationsHandler = {
            [TaskNotification(id: "t1", title: "Downloading", group: "download_pending",
                              messages: ["m"], progress: 0.5, isError: false, canStop: true)]
        }
        var fetchedPages: [Int] = []
        repo.getDownloadsHandler = { page, _ in
            fetchedPages.append(page)
            let last = page >= 3 ? 0 : 3
            return TestData.downloadListResult(
                count: 3, startIndex: (page - 1) * 3, currentPage: page, lastPage: last
            )
        }

        // First tick: reconcile at full depth; the bogus last_page 0 must NOT collapse depth.
        let keep1 = await vm.performPollTick()
        #expect(keep1 == true)
        #expect(vm.items.count == 9)
        #expect(Set(fetchedPages) == Set([1, 2, 3]))

        // Second tick previously surfaced the collapse (fetchAllLoadedPages(upTo: 0) -> page 1
        // only, items 9 -> 3). Depth must stay preserved.
        fetchedPages.removeAll()
        let keep2 = await vm.performPollTick()
        #expect(keep2 == true)
        #expect(vm.items.count == 9)
        #expect(Set(fetchedPages) == Set([1, 2, 3]))

        vm.stopPolling()
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
