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
    var isLoadingMore = false
    var downloadProgress: [DownloadTaskInfo] = []

    private var currentPage = 1
    private var lastPage = 1
    private var canLoadMore: Bool { currentPage < lastPage && !isLoadingMore }
    private var pollingTask: Task<Void, Never>?
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
        } catch let error as AppError {
            if case .unauthorized = error {
                router.handleUnauthorized()
            } else {
                errorMessage = error.errorDescription
            }
        } catch {
            errorMessage = String(localized: "error_generic")
        }

        isLoading = false
    }

    func refresh() async {
        await loadDownloads(isRefresh: true)
    }

    func onFilterChanged() async {
        await loadDownloads()
    }

    func loadMoreIfNeeded() async {
        guard canLoadMore else { return }
        isLoadingMore = true

        let nextPage = currentPage + 1
        do {
            let result = try await downloadRepository.getDownloads(page: nextPage, filter: filter)
            items.append(contentsOf: result.items)
            currentPage = result.currentPage
            lastPage = result.lastPage
        } catch let error as AppError {
            if case .unauthorized = error {
                router.handleUnauthorized()
            }
        } catch {}

        isLoadingMore = false
    }

    func updateStatus(videoId: String, status: String) async {
        do {
            try await downloadRepository.updateStatus(videoId: videoId, status: status)
            items.removeAll { $0.youtubeId == videoId }
        } catch let error as AppError {
            if case .unauthorized = error {
                router.handleUnauthorized()
            } else {
                errorMessage = error.errorDescription
            }
        } catch {
            errorMessage = String(localized: "error_generic")
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
        } catch let error as AppError {
            if case .unauthorized = error {
                router.handleUnauthorized()
            } else {
                errorMessage = error.errorDescription
            }
        } catch {
            errorMessage = String(localized: "error_generic")
        }
        isAdding = false
    }

    func startDownload() async {
        isStartingDownload = true
        do {
            try await downloadRepository.startDownload()
            startPolling()
        } catch let error as AppError {
            if case .unauthorized = error {
                router.handleUnauthorized()
            } else {
                errorMessage = error.errorDescription
            }
        } catch {
            errorMessage = String(localized: "error_generic")
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
        } catch let error as AppError {
            if case .unauthorized = error {
                router.handleUnauthorized()
            } else {
                errorMessage = error.errorDescription
            }
        } catch {
            errorMessage = String(localized: "error_generic")
        }
    }

    func checkNotifications() async {
        do {
            let notifications = try await downloadRepository.getDownloadNotifications()
            if !notifications.isEmpty {
                downloadProgress = notifications
                startPolling()
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
                    let notifications = try await downloadRepository.getDownloadNotifications()

                    if notifications.isEmpty {
                        downloadProgress = []
                        await loadDownloads(isRefresh: true)
                        break
                    }

                    downloadProgress = notifications

                    if filter == "pending" {
                        let result = try await downloadRepository.getDownloads(page: 1, filter: "pending")
                        items = result.items
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
        do {
            try await downloadRepository.updateStatus(videoId: videoId, status: "priority")
            try await downloadRepository.startDownload()
            startPolling()
        } catch let error as AppError {
            if case .unauthorized = error {
                router.handleUnauthorized()
            } else {
                errorMessage = error.errorDescription
            }
        } catch {
            errorMessage = String(localized: "error_generic")
        }
    }

    func deleteItem(videoId: String) async {
        do {
            try await downloadRepository.deleteDownload(videoId: videoId)
            items.removeAll { $0.youtubeId == videoId }
        } catch let error as AppError {
            if case .unauthorized = error {
                router.handleUnauthorized()
            } else {
                errorMessage = error.errorDescription
            }
        } catch {
            errorMessage = String(localized: "error_generic")
        }
    }
}
