import Foundation

@Observable
final class DownloadQueueViewModel {
    var items: [DownloadItem] = []
    var isLoading = false
    var errorMessage: String?
    var filter: String = "pending"
    var addInput: String = ""
    var isAdding = false
    var isStartingDownload = false
    var isRescanningSubscriptions = false
    var isLoadingMore = false
    var downloadProgress: [TaskNotification] = []

    private var currentPage = 1
    private var lastPage = 1
    private var canLoadMore: Bool { currentPage < lastPage && !isLoadingMore }
    private var pollingTask: Task<Void, Never>?

    /// Consecutive polling ticks seen with no active download. A single idle tick is
    /// NOT proof the batch finished — it also occurs during `download_pending` startup
    /// latency and in the quiet gap between two videos (indexing / thumbnail work emits
    /// no `download`-prefixed group). Polling stops only after `maxIdlePollsBeforeStop`
    /// consecutive idle ticks (or instantly via the drained-queue fast-stop). Reset on any
    /// active tick and at `startPolling`.
    private var consecutiveIdlePolls = 0
    /// ~12s (4 × 3s tick) of confirmed inactivity before declaring a non-drained queue
    /// finished. `internal static` (not private) so tests read the bound instead of
    /// hardcoding tick counts — treat as a test seam, like `performPollTick`.
    static let maxIdlePollsBeforeStop = 4
    private var pendingRemovals: Set<String> = []
    private var downloadItemQueue: Set<String> = []
    private var isProcessingDownloadQueue = false
    private let downloadRepository: DownloadRepositoryProtocol
    private let router: AppRouter

    init(downloadRepository: DownloadRepositoryProtocol, router: AppRouter) {
        self.downloadRepository = downloadRepository
        self.router = router
    }

    func loadDownloads(isRefresh: Bool = false) async {
        if !isRefresh {
            isLoading = true
        }
        errorMessage = nil

        do {
            let result = try await downloadRepository.getDownloads(page: 1, filter: filter)
            items = result.items
            currentPage = result.currentPage
            lastPage = result.lastPage
        } catch {
            router.handleError(error, errorMessage: &errorMessage)
        }

        isLoading = false
    }

    func refresh() async {
        pendingRemovals.removeAll()
        await loadDownloads(isRefresh: true)
    }

    func onFilterChanged() async {
        pendingRemovals.removeAll()
        await loadDownloads()
    }

    func loadMoreIfNeeded() async {
        guard canLoadMore else { return }
        isLoadingMore = true

        let nextPage = currentPage + 1
        do {
            let result = try await downloadRepository.getDownloads(page: nextPage, filter: filter)
            let existingIds = Set(items.map(\.youtubeId))
            items.append(contentsOf: result.items.filter { !existingIds.contains($0.youtubeId) })
            currentPage = result.currentPage
            lastPage = result.lastPage
        } catch {
            router.handleError(error, errorMessage: &errorMessage)
        }

        isLoadingMore = false
    }

    func updateStatus(videoId: String, status: String) async {
        pendingRemovals.insert(videoId)
        items.removeAll { $0.youtubeId == videoId }

        do {
            try await downloadRepository.updateStatus(videoId: videoId, status: status)
        } catch {
            pendingRemovals.remove(videoId)
            if !router.handleError(error, errorMessage: &errorMessage) {
                await reloadPreservingDepth()
            }
        }
    }

    func addToQueue() async {
        let input = addInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        isAdding = true
        do {
            try await downloadRepository.addToQueue(videoId: input)
            addInput = ""
            await reloadPreservingDepth()
        } catch {
            router.handleError(error, errorMessage: &errorMessage)
        }
        isAdding = false
    }

    func startDownload() async {
        isStartingDownload = true
        do {
            try await downloadRepository.startDownload()
            startPolling()
        } catch {
            router.handleError(error, errorMessage: &errorMessage)
        }
        isStartingDownload = false
    }

    func stopCurrentDownload() async {
        guard let task = downloadProgress.first(where: { $0.canStop }) else { return }
        do {
            try await downloadRepository.killTask(id: task.id)
            stopPolling()
            downloadProgress = []
            await reloadPreservingDepth()
        } catch {
            router.handleError(error, errorMessage: &errorMessage)
        }
    }

    func rescanSubscriptions() async {
        isRescanningSubscriptions = true
        do {
            try await downloadRepository.rescanSubscriptions()
            startPolling()
        } catch {
            router.handleError(error, errorMessage: &errorMessage)
        }
        isRescanningSubscriptions = false
    }

    func checkNotifications() async {
        do {
            let notifications = try await downloadRepository.getNotifications()
            if !notifications.isEmpty {
                downloadProgress = notifications
                if notifications.contains(where: { $0.group.hasPrefix("download") }) {
                    startPolling()
                }
            }
        } catch {}
    }

    func startPolling() {
        guard pollingTask == nil else { return }
        consecutiveIdlePolls = 0
        pollingTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    break
                }

                let keepPolling = await performPollTick()
                if !keepPolling { break }
            }
            pollingTask = nil
        }
    }

    /// Executes a single polling tick. Returns `true` to keep polling, `false` to stop.
    /// Internal (not private) so tests can drive the reconcile logic without the 3s sleep.
    func performPollTick() async -> Bool {
        do {
            let notifications = try await downloadRepository.getNotifications()
            let hasActiveDownload = notifications.contains { $0.group.hasPrefix("download") }

            if hasActiveDownload {
                consecutiveIdlePolls = 0
                downloadProgress = notifications
                try await reconcileLoadedPages()
                return true
            }

            // No active download THIS tick — could be true completion OR a transient gap
            // (startup latency / between-videos indexing). Reconcile first, then decide.
            try await reconcileLoadedPages()

            // Fast-stop: the pending queue drained -> definitely finished.
            if filter == "pending", items.isEmpty {
                pendingRemovals.removeAll()
                downloadProgress = notifications // empty -> banner hides
                consecutiveIdlePolls = 0
                return false
            }

            // Grace window: tolerate inter-video gaps without killing the loop.
            consecutiveIdlePolls += 1
            if consecutiveIdlePolls >= Self.maxIdlePollsBeforeStop {
                pendingRemovals.removeAll()
                downloadProgress = notifications
                consecutiveIdlePolls = 0
                return false
            }
            // Within grace: keep the banner stable (don't blank to empty between videos).
            if !notifications.isEmpty { downloadProgress = notifications }
            return true
        } catch is CancellationError {
            return false
        } catch {
            // transient error — keep polling, retry next tick
            return true
        }
    }

    /// Refetches all currently-loaded pages of the pending list, reconciles `items`,
    /// and clamps pagination — preserving the loaded depth (never collapses to page 1).
    ///
    /// Filter-aware: `fetchAllLoadedPages` always reads `filter: "pending"`, so this is
    /// a no-op on the ignore tab. The guard is re-checked AFTER the await because the
    /// fetch is a suspension point and `onFilterChanged` (View `.onChange`, not gated by
    /// `stopPolling`) can switch tabs mid-fetch — applying pending data then would clobber
    /// the ignore tab with the wrong list (TOCTOU). On a mid-await switch we drop the
    /// stale pending data entirely.
    private func reconcileLoadedPages() async throws {
        guard filter == "pending" else { return }
        // Snapshot the loaded depth: `fetchAllLoadedPages` reads pages 1...currentPage,
        // so its result reflects this depth. The await below is a suspension point.
        let depthBefore = currentPage
        let (newItems, newLastPage) = try await fetchAllLoadedPages(filter: "pending", upTo: depthBefore)
        // Re-check BOTH the filter (mid-await `onFilterChanged`, see doc comment) AND the
        // loaded depth: a concurrent `loadMoreIfNeeded` can advance `currentPage` and append
        // a new page to `items` while we were awaiting. Applying the shallow snapshot now would
        // drop that just-loaded page and clamp the scroll back — defeating stable-scroll. Drop
        // the stale snapshot; the next 3s tick reconciles cleanly at the new depth.
        guard filter == "pending", currentPage == depthBefore else { return }
        applyPolledItems(newItems)
        (lastPage, currentPage) = clampDepth(newLastPage: newLastPage, currentPage: currentPage)
    }

    /// Depth-preserving reload after a mutation (add / stop / error recovery).
    /// Refetches pages 1...currentPage for the CURRENT filter and reconciles via
    /// `applyPolledItems` — never collapses to page 1, so the scroll position is kept.
    /// Does not toggle `isLoading` (silent refresh, no full-screen spinner flash).
    ///
    /// NOTE: unlike `reconcileLoadedPages` (which throws so `performPollTick` can swallow
    /// transient errors and keep polling), this surfaces failures via `router.handleError`
    /// — mutation reloads are user-initiated and should report. Do not "unify" the two
    /// error strategies. Filter-aware: works on both the pending and ignore tabs (the
    /// pending-only no-op of `reconcileLoadedPages` is a polling concern, not a reload one).
    private func reloadPreservingDepth() async {
        let depthBefore = currentPage
        let activeFilter = filter
        do {
            let (newItems, newLastPage) = try await fetchAllLoadedPages(
                filter: activeFilter, upTo: depthBefore
            )
            // Drop the snapshot if the user switched tabs or `loadMoreIfNeeded` advanced
            // depth while we were awaiting — same TOCTOU guard as `reconcileLoadedPages`.
            guard filter == activeFilter, currentPage == depthBefore else { return }
            applyPolledItems(newItems)
            (lastPage, currentPage) = clampDepth(newLastPage: newLastPage, currentPage: currentPage)
        } catch {
            router.handleError(error, errorMessage: &errorMessage)
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func downloadItem(videoId: String) async {
        downloadItemQueue.insert(videoId)
        guard !isProcessingDownloadQueue else { return }
        isProcessingDownloadQueue = true
        defer { isProcessingDownloadQueue = false }

        while let id = downloadItemQueue.first {
            downloadItemQueue.remove(id)
            do {
                try await downloadRepository.updateStatus(videoId: id, status: "priority")
            } catch {
                if router.handleError(error, errorMessage: &errorMessage) { return }
                continue // non-auth error: skip removal for this id, process the rest
            }

            // `status: "priority"` pulls the video OUT of the ignore list into the download
            // queue. On the ignore tab the row no longer belongs here, so drop it with a
            // SURGICAL in-place removal — the same pattern as `deleteItem` / `updateStatus`.
            //
            // Do NOT reassign the whole array here (e.g. `reloadPreservingDepth`): this code
            // runs inside the LEADING swipe action's Task, and replacing `items` mid-swipe
            // makes UICollectionView drop the triggered swipe's mask view and reset
            // contentOffset to the top ("unexpected removal of the current swipe occurrence's
            // mask view" + list jumps to the top). A single-row removal SwiftUI List animates
            // in place, so the scroll position and the in-flight swipe are preserved.
            //
            // On the pending tab the item stays pending and in place — mutate nothing; the
            // next poll tick surfaces its new prioritised order without a jump.
            if filter == "ignore" {
                items.removeAll { $0.youtubeId == id }
            }
        }

        if pollingTask == nil {
            do {
                try await downloadRepository.startDownload()
            } catch {
                router.handleError(error, errorMessage: &errorMessage)
                return
            }
        }
        startPolling()
    }

    func deleteItem(videoId: String) async {
        pendingRemovals.insert(videoId)
        items.removeAll { $0.youtubeId == videoId }

        do {
            try await downloadRepository.deleteDownload(videoId: videoId)
        } catch {
            pendingRemovals.remove(videoId)
            if !router.handleError(error, errorMessage: &errorMessage) {
                await reloadPreservingDepth()
            }
        }
    }

    // MARK: - Private

    private func fetchAllLoadedPages(
        filter: String, upTo pages: Int
    ) async throws -> (items: [DownloadItem], lastPage: Int) {
        // Never fetch fewer than 1 page — a corrupted/degenerate `currentPage` (e.g. clamped
        // to 0 by a bogus `last_page`) must not silently reduce this to a page-1-only refetch.
        let pagesToFetch = max(1, pages)
        if pagesToFetch <= 1 {
            let result = try await downloadRepository.getDownloads(page: 1, filter: filter)
            return (result.items, result.lastPage)
        }

        return try await withThrowingTaskGroup(
            of: (Int, DownloadListResult).self
        ) { group in
            for page in 1...pagesToFetch {
                group.addTask {
                    let result = try await self.downloadRepository.getDownloads(page: page, filter: filter)
                    return (page, result)
                }
            }

            var pageResults: [(Int, DownloadListResult)] = []
            for try await result in group {
                pageResults.append(result)
            }

            pageResults.sort { $0.0 < $1.0 }
            // Dedup by youtubeId (preserve first occurrence / server order) so API page
            // drift can't produce duplicate ids — mirrors `loadMoreIfNeeded`. Duplicate
            // ids would trip SwiftUI's `ForEach(..., id: \.id)` and mis-animate.
            var seen = Set<String>()
            var merged: [DownloadItem] = []
            for (_, result) in pageResults {
                for item in result.items where seen.insert(item.youtubeId).inserted {
                    merged.append(item)
                }
            }
            let newLastPage = pageResults.last?.1.lastPage ?? 1
            return (merged, newLastPage)
        }
    }

    /// Reconciles `items` with freshly polled data, filtering out anything in
    /// `pendingRemovals` and adopting the server order. Returns `true` when `items`
    /// was reassigned, `false` when the filtered result equals the current `items`
    /// (the short-circuit — no reassignment, so SwiftUI sees no change).
    /// Internal (not private) so tests can drive the reconcile/short-circuit directly.
    @discardableResult
    func applyPolledItems(_ newItems: [DownloadItem]) -> Bool {
        let filtered = newItems.filter { !pendingRemovals.contains($0.youtubeId) }
        if filtered != items {
            items = filtered
            return true
        }
        return false
    }

    /// Reconciles the freshly reported `newLastPage` against the loaded depth without ever
    /// collapsing it. TA reports `last_page: 0` on the final page (see `DownloadRepositoryImpl`
    /// for the primary fix); this is the defense-in-depth backstop so ANY non-positive /
    /// below-depth `lastPage` can't clamp `currentPage` to 0 and make the next
    /// `fetchAllLoadedPages(upTo:)` refetch only page 1 (the download-queue collapse-to-top
    /// bug). Returns `(lastPage, currentPage)`: a non-positive `newLastPage` keeps the current
    /// depth; otherwise `currentPage` is clamped down to a genuinely-smaller last page (real
    /// queue shrink) but never below 1.
    private func clampDepth(newLastPage: Int, currentPage: Int) -> (lastPage: Int, currentPage: Int) {
        guard newLastPage >= 1 else { return (max(lastPage, currentPage), currentPage) }
        return (newLastPage, max(1, min(currentPage, newLastPage)))
    }
}
