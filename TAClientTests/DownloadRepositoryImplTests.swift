import Testing
import Foundation
@testable import TAClient

extension DataLayerSuite {
@Suite(.serialized) struct DownloadRepositoryImplTests {

    init() {
        MockResponse.tearDown()
    }

    private func makeRepo() -> (DownloadRepositoryImpl, AuthState) {
        let (client, authState) = MockResponse.makeAPIClient()
        let repo = DownloadRepositoryImpl(apiClient: client, authState: authState)
        return (repo, authState)
    }

    // MARK: - getDownloads

    @Test func getDownloads_success_mapsPaginationAndURLs() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(json: [
            "data": [
                [
                    "youtube_id": "dl1",
                    "title": "Download Video",
                    "channel_name": "Channel",
                    "channel_id": "ch1",
                    "duration": "5:00",
                    "published": "2024-01-15",
                    "status": "pending",
                    "vid_thumb_url": "/cache/dl-thumb.jpg",
                    "vid_type": "videos",
                    "timestamp": 1704067200
                ]
            ],
            "paginate": [
                "current_page": 1,
                "last_page": 2
            ]
        ] as [String: Any])

        let result = try await repo.getDownloads(page: 1, filter: "pending")
        #expect(result.currentPage == 1)
        #expect(result.lastPage == 2)
        #expect(result.items.count == 1)
        #expect(result.items[0].youtubeId == "dl1")
        #expect(result.items[0].thumbUrl == "https://ta.example.com/cache/dl-thumb.jpg")
        #expect(MockURLProtocol.lastRequest?.url?.absoluteString.contains("filter=pending") == true)
        authState.handleUnauthorized()
    }

    // MARK: - updateStatus

    @Test func updateStatus_sendsPost() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(statusCode: 200, data: Data())

        try await repo.updateStatus(videoId: "dl1", status: "priority")

        #expect(MockURLProtocol.lastRequest?.httpMethod == "POST")
        #expect(MockURLProtocol.lastRequest?.url?.path.contains("/api/download/dl1") == true)
        authState.handleUnauthorized()
    }

    // MARK: - deleteDownload

    @Test func deleteDownload_sendsDelete() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(statusCode: 200, data: Data())

        try await repo.deleteDownload(videoId: "dl1")

        #expect(MockURLProtocol.lastRequest?.httpMethod == "DELETE")
        #expect(MockURLProtocol.lastRequest?.url?.path.contains("/api/download/dl1") == true)
        authState.handleUnauthorized()
    }

    // MARK: - addToQueue

    @Test func addToQueue_sendsPost() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(statusCode: 200, data: Data())

        try await repo.addToQueue(videoId: "new-vid")

        #expect(MockURLProtocol.lastRequest?.httpMethod == "POST")
        #expect(MockURLProtocol.lastRequest?.url?.path.contains("/api/download") == true)

        // Verify body
        guard let bodyData = MockURLProtocol.lastRequestBody else {
            Issue.record("Expected request body to be captured")
            return
        }
        let body = try JSONSerialization.jsonObject(with: bodyData) as! [String: Any]
        let dataArray = body["data"] as! [[String: Any]]
        #expect(dataArray.count == 1)
        #expect(dataArray[0]["youtube_id"] as? String == "new-vid")
        #expect(dataArray[0]["status"] as? String == "pending")
        authState.handleUnauthorized()
    }

    // MARK: - startDownload

    @Test func startDownload_sendsPostToTaskEndpoint() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(statusCode: 200, data: Data())

        try await repo.startDownload()

        #expect(MockURLProtocol.lastRequest?.httpMethod == "POST")
        #expect(MockURLProtocol.lastRequest?.url?.path.contains("/api/task/by-name/download_pending") == true)
        authState.handleUnauthorized()
    }

    // MARK: - getNotifications

    @Test func getNotifications_mapsNotifications() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(json: [
            [
                "id": "task-1",
                "title": "Downloading video",
                "group": "download:add",
                "level": "info",
                "messages": ["Downloading 1/3"],
                "progress": 0.33,
                "api_stop": true
            ],
            [
                "id": "task-2",
                "title": "Error occurred",
                "group": "rescan:filesystem",
                "level": "error",
                "messages": ["Network error"],
                "progress": 0.0,
                "api_stop": false
            ]
        ] as [[String: Any]])

        let notifications = try await repo.getNotifications()
        #expect(notifications.count == 2)

        #expect(notifications[0].id == "task-1")
        #expect(notifications[0].title == "Downloading video")
        #expect(notifications[0].group == "download:add")
        #expect(notifications[0].progress == 0.33)
        #expect(notifications[0].isError == false)
        #expect(notifications[0].canStop == true)

        #expect(notifications[1].id == "task-2")
        #expect(notifications[1].group == "rescan:filesystem")
        #expect(notifications[1].isError == true)
        #expect(notifications[1].canStop == false)
        authState.handleUnauthorized()
    }

    // MARK: - killTask

    @Test func killTask_sendsPostToTaskEndpoint() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(statusCode: 200, data: Data())

        try await repo.killTask(id: "task-1")

        #expect(MockURLProtocol.lastRequest?.httpMethod == "POST")
        #expect(MockURLProtocol.lastRequest?.url?.path.contains("/api/task/by-id/task-1") == true)
        authState.handleUnauthorized()
    }
}
}
