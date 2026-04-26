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

                do {
                    let notifications = try await downloadRepository.getNotifications()
                    let hasActiveDownload = notifications.contains { $0.group.hasPrefix("download") }

                    downloadProgress = notifications

                    if !hasActiveDownload {
                        pendingRemovals.removeAll()
                        await loadDownloads(isRefresh: true)
                        downloadProgress = notifications.isEmpty ? [] : notifications
                        break
                    }

                    if filter == "pending" {
                        let (newItems, newLastPage) = try await fetchAllLoadedPages()
                        applyPolledItems(newItems)
                        lastPage = newLastPage
                        if currentPage > newLastPage {
                            currentPage = newLastPage
                        }
                    }
                } catch is CancellationError {
                    break
                } catch {
                    // transient error — keep polling
                }
            }
            pollingTask = nil
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
            let merged = pageResults.flatMap { $0.1.items }
            let newLastPage = pageResults.last?.1.lastPage ?? 1
            return (merged, newLastPage)
        }
    }

    private func applyPolledItems(_ newItems: [DownloadItem]) {
        let filtered = newItems.filter { !pendingRemovals.contains($0.youtubeId) }
        if filtered != items {
            items = filtered
        }
    }
}
