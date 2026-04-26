import Testing
import Foundation
@testable import TAClient

extension DataLayerSuite {
@Suite(.serialized) struct VideoRepositoryImplTests {

    init() {
        MockResponse.tearDown()
    }

    private func makeRepo() -> (VideoRepositoryImpl, AuthState) {
        let (client, authState) = MockResponse.makeAPIClient()
        let repo = VideoRepositoryImpl(apiClient: client, authState: authState)
        return (repo, authState)
    }

    // MARK: - getVideos

    @Test func getVideos_success_mapsPaginationAndURLs() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(json: [
            "data": [
                [
                    "youtube_id": "vid1",
                    "title": "Test Video",
                    "published": "2024-01-15",
                    "channel": ["channel_id": "ch1", "channel_name": "Channel 1", "channel_thumb_url": "/cache/ch-thumb.jpg"],
                    "vid_thumb_url": "/cache/thumb.jpg",
                    "media_url": "/cache/video.mp4",
                    "player": ["watched": false, "duration": 600, "duration_str": "10:00", "progress": 0.0, "position": 0.0],
                    "stats": ["view_count": 1000, "like_count": 50],
                    "media_size": 50000000,
                    "vid_type": "videos"
                ]
            ],
            "paginate": [
                "current_page": 1,
                "last_page": 3,
                "total_hits": 75
            ]
        ] as [String: Any])

        let result = try await repo.getVideos(page: 1, sort: "date", order: "desc", watch: nil, channel: nil, vidType: nil)

        #expect(result.currentPage == 1)
        #expect(result.lastPage == 3)
        #expect(result.totalHits == 75)
        #expect(result.videos.count == 1)
        #expect(result.videos[0].youtubeId == "vid1")
        #expect(result.videos[0].thumbUrl == "https://ta.example.com/cache/thumb.jpg")
        #expect(result.videos[0].mediaUrl == "https://ta.example.com/cache/video.mp4")
        #expect(result.videos[0].channelThumbUrl == "https://ta.example.com/cache/ch-thumb.jpg")
        authState.handleUnauthorized()
    }

    @Test func getVideos_emptyData_returnsEmptyList() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(json: [
            "data": [] as [Any],
            "paginate": ["current_page": 1, "last_page": 1, "total_hits": 0]
        ] as [String: Any])

        let result = try await repo.getVideos(page: 1, sort: "date", order: "desc", watch: nil, channel: nil, vidType: nil)
        #expect(result.videos.isEmpty)
        authState.handleUnauthorized()
    }

    @Test func getVideos_401_throwsUnauthorized() async {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(statusCode: 401, json: ["detail": "Invalid token"])

        await #expect(throws: AppError.self) {
            _ = try await repo.getVideos(page: 1, sort: "date", order: "desc", watch: nil, channel: nil, vidType: nil)
        }
        authState.handleUnauthorized()
    }

    @Test func getVideos_withVidType_sendsQueryParam() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(json: [
            "data": [] as [Any],
            "paginate": ["current_page": 1, "last_page": 1, "total_hits": 0]
        ] as [String: Any])

        _ = try await repo.getVideos(page: 1, sort: "date", order: "desc", watch: nil, channel: nil, vidType: "shorts")

        let url = MockURLProtocol.lastRequest?.url?.absoluteString ?? ""
        #expect(url.contains("type=shorts"))
        authState.handleUnauthorized()
    }

    // MARK: - setWatched

    @Test func setWatched_sendsPost() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(statusCode: 200, data: Data())

        try await repo.setWatched(videoId: "vid1", isWatched: true)

        #expect(MockURLProtocol.lastRequest?.httpMethod == "POST")
        #expect(MockURLProtocol.lastRequest?.url?.path.contains("/api/watched") == true)
        authState.handleUnauthorized()
    }

    // MARK: - getVideo

    @Test func getVideo_success_mapsAllFields() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(json: [
            "youtube_id": "vid1",
            "title": "My Video",
            "description": "A great video",
            "published": "2024-06-15",
            "channel": ["channel_id": "ch1", "channel_name": "Ch"],
            "vid_thumb_url": "/cache/thumb.jpg",
            "media_url": "/cache/video.mp4",
            "player": ["watched": true, "duration": 300, "duration_str": "5:00", "progress": 0.5, "position": 150.0],
            "stats": ["view_count": 2000, "like_count": 100],
            "media_size": 100000000,
            "vid_type": "videos",
            "streams": [
                ["type": "video", "codec": "h264", "bitrate": 5000000, "width": 1920, "height": 1080]
            ]
        ] as [String: Any])

        let video = try await repo.getVideo(id: "vid1")
        #expect(video.youtubeId == "vid1")
        #expect(video.title == "My Video")
        #expect(video.watched == true)
        #expect(video.duration == 300)
        #expect(video.position == 150.0)
        #expect(video.viewCount == 2000)
        #expect(video.streams.count == 1)
        #expect(video.streams[0].codec == "h264")
        authState.handleUnauthorized()
    }

    @Test func getVideo_missingRequiredFields_throwsDecoding() async {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(json: ["description": "no id or title"] as [String: Any])

        do {
            _ = try await repo.getVideo(id: "vid1")
            Issue.record("Expected AppError.decoding")
        } catch let error as AppError {
            if case .decoding = error {} else {
                Issue.record("Expected .decoding, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        authState.handleUnauthorized()
    }

    // MARK: - updateProgress

    @Test func updateProgress_sendsCorrectEndpoint() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(statusCode: 200, data: Data())

        try await repo.updateProgress(videoId: "vid1", position: 42.0)

        #expect(MockURLProtocol.lastRequest?.httpMethod == "POST")
        #expect(MockURLProtocol.lastRequest?.url?.path.contains("/api/video/vid1/progress") == true)
        authState.handleUnauthorized()
    }

    // MARK: - deleteProgress

    @Test func deleteProgress_sendsDelete() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(statusCode: 200, data: Data())

        try await repo.deleteProgress(videoId: "vid1")

        #expect(MockURLProtocol.lastRequest?.httpMethod == "DELETE")
        #expect(MockURLProtocol.lastRequest?.url?.path.contains("/api/video/vid1/progress") == true)
        authState.handleUnauthorized()
    }

    // MARK: - deleteVideo

    @Test func deleteVideo_sendsDelete() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(statusCode: 200, data: Data())

        try await repo.deleteVideo(id: "vid1")

        #expect(MockURLProtocol.lastRequest?.httpMethod == "DELETE")
        #expect(MockURLProtocol.lastRequest?.url?.path.contains("/api/video/vid1") == true)
        authState.handleUnauthorized()
    }

    // MARK: - ignoreVideo

    @Test func ignoreVideo_sendsPostToDownloadEndpoint() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(statusCode: 200, data: Data())

        try await repo.ignoreVideo(id: "vid1")

        #expect(MockURLProtocol.lastRequest?.httpMethod == "POST")
        #expect(MockURLProtocol.lastRequest?.url?.path.contains("/api/download/vid1") == true)
        authState.handleUnauthorized()
    }

    // MARK: - getComments

    @Test func getComments_success_mapsFields() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(json: [
            [
                "comment_id": "c1",
                "comment_author": "User1",
                "comment_author_id": "author1",
                "comment_author_thumbnail": "/cache/author-thumb.jpg",
                "comment_author_is_uploader": false,
                "comment_text": "Great video!",
                "comment_time_text": "1 day ago",
                "comment_likecount": 5,
                "comment_is_favorited": false,
                "comment_parent": "root",
                "comment_replies": [] as [Any]
            ]
        ] as [[String: Any]])

        let comments = try await repo.getComments(videoId: "vid1")
        #expect(comments.count == 1)
        #expect(comments[0].id == "c1")
        #expect(comments[0].author == "User1")
        #expect(comments[0].text == "Great video!")
        #expect(comments[0].authorThumbnailUrl == "https://ta.example.com/cache/author-thumb.jpg")
        authState.handleUnauthorized()
    }
}
}
