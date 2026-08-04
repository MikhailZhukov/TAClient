import Foundation

final class DownloadRepositoryImpl: DownloadRepositoryProtocol {
    private let apiClient: APIClient
    private let authState: AuthState

    init(apiClient: APIClient, authState: AuthState) {
        self.apiClient = apiClient
        self.authState = authState
    }

    private var serverURL: String {
        authState.serverURL ?? ""
    }

    func getDownloads(page: Int, filter: String) async throws -> DownloadListResult {
        let response: DownloadListResponseDTO = try await apiClient.request(
            endpoint: .downloadList(page: page, filter: filter)
        )

        let items = response.data?.compactMap { DownloadMapper.map($0, serverURL: serverURL) } ?? []
        let resolvedPage = response.paginate?.currentPage ?? page
        // TA returns `last_page: 0` when the requested page IS the final page (pages before
        // the last correctly report the real total). Trusting that 0 verbatim collapses the
        // download queue: the polling reconcile clamps `currentPage = min(currentPage, 0) = 0`,
        // and the next `fetchAllLoadedPages(upTo: 0)` then refetches only page 1 — throwing a
        // deep-scrolled list back to the top. Treat a non-positive `last_page` as "this page
        // is the last one" so `lastPage` is never below the page we actually loaded.
        let reportedLast = response.paginate?.lastPage ?? resolvedPage
        let resolvedLast = reportedLast > 0 ? reportedLast : resolvedPage
        return DownloadListResult(
            items: items,
            currentPage: resolvedPage,
            lastPage: resolvedLast
        )
    }

    func updateStatus(videoId: String, status: String) async throws {
        try await apiClient.requestVoid(
            endpoint: .updateDownloadStatus(id: videoId),
            body: DownloadStatusDTO(status: status)
        )
    }

    func deleteDownload(videoId: String) async throws {
        try await apiClient.requestVoid(endpoint: .deleteDownload(id: videoId))
    }

    func addToQueue(videoId: String) async throws {
        try await apiClient.requestVoid(
            endpoint: .addToDownloadQueue,
            body: AddToDownloadListDTO(data: [AddDownloadItemDTO(youtubeId: videoId, status: "pending")])
        )
    }

    func startDownload() async throws {
        try await apiClient.requestVoid(endpoint: .startDownload)
    }

    func getNotifications() async throws -> [TaskNotification] {
        let notifications: [NotificationDTO] = try await apiClient.request(
            endpoint: .notifications
        )

        return notifications.map { dto in
            TaskNotification(
                id: dto.id ?? "",
                title: dto.title ?? "",
                group: dto.group ?? "",
                messages: dto.messages ?? [],
                progress: dto.progress ?? 0,
                isError: dto.level == "error",
                canStop: dto.apiStop ?? false
            )
        }
    }

    func killTask(id: String) async throws {
        try await apiClient.requestVoid(
            endpoint: .killTask(id: id),
            body: TaskCommandDTO(command: "stop")
        )
    }

    func rescanSubscriptions() async throws {
        try await apiClient.requestVoid(endpoint: .rescanSubscriptions)
    }
}
