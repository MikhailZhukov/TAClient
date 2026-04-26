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
        return DownloadListResult(
            items: items,
            currentPage: response.paginate?.currentPage ?? page,
            lastPage: response.paginate?.lastPage ?? page
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
