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
                await loadDownloads(isRefresh: true)
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
            await loadDownloads(isRefresh: true)
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
            await loadDownloads(isRefresh: true)
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

            downloadProgress = notifications

            if !hasActiveDownload {
                // Batch finished — clear optimistic-removal tracking, then reconcile.
                pendingRemovals.removeAll()
                try await reconcileLoadedPages()
                return false
            }

            try await reconcileLoadedPages()
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
        let (newItems, newLastPage) = try await fetchAllLoadedPages()
        // Re-check BOTH the filter (mid-await `onFilterChanged`, see doc comment) AND the
        // loaded depth: a concurrent `loadMoreIfNeeded` can advance `currentPage` and append
        // a new page to `items` while we were awaiting. Applying the shallow snapshot now would
        // drop that just-loaded page and clamp the scroll back — defeating stable-scroll. Drop
        // the stale snapshot; the next 3s tick reconciles cleanly at the new depth.
        guard filter == "pending", currentPage == depthBefore else { return }
        applyPolledItems(newItems)
        lastPage = newLastPage
        currentPage = min(currentPage, newLastPage)
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
                await loadDownloads(isRefresh: true)
            }
        }
    }

    // MARK: - Private

    private func fetchAllLoadedPages() async throws -> (items: [DownloadItem], lastPage: Int) {
        let pagesToFetch = currentPage
        if pagesToFetch <= 1 {
            let result = try await downloadRepository.getDownloads(page: 1, filter: "pending")
            return (result.items, result.lastPage)
        }

        return try await withThrowingTaskGroup(
            of: (Int, DownloadListResult).self
        ) { group in
            for page in 1...pagesToFetch {
                group.addTask {
                    let result = try await self.downloadRepository.getDownloads(page: page, filter: "pending")
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
}
