import Testing
import Foundation
@testable import TAClient

extension DataLayerSuite {
@Suite(.serialized) struct SearchRepositoryImplTests {

    init() {
        MockResponse.tearDown()
    }

    private func makeRepo() -> (SearchRepositoryImpl, AuthState) {
        let (client, authState) = MockResponse.makeAPIClient()
        let repo = SearchRepositoryImpl(apiClient: client, authState: authState)
        return (repo, authState)
    }

    // MARK: - search

    @Test func search_success_returnsVideosAndChannels() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(json: [
            "results": [
                "video_results": [
                    [
                        "youtube_id": "sv1",
                        "title": "Search Result Video",
                        "published": "2024-03-01",
                        "channel": ["channel_id": "ch1", "channel_name": "Ch"],
                        "vid_thumb_url": "/cache/search-thumb.jpg",
                        "media_url": "/cache/search-video.mp4",
                        "player": ["watched": false, "duration": 120, "duration_str": "2:00"],
                        "stats": ["view_count": 500],
                        "vid_type": "videos"
                    ]
                ],
                "channel_results": [
                    [
                        "channel_id": "ch-search",
                        "channel_name": "Found Channel",
                        "channel_thumb_url": "/cache/ch-search.jpg",
                        "channel_subs": 1000,
                        "channel_subscribed": true
                    ]
                ]
            ]
        ] as [String: Any])

        let result = try await repo.search(query: "test query", page: 1)
        #expect(result.videos.count == 1)
        #expect(result.videos[0].youtubeId == "sv1")
        #expect(result.videos[0].thumbUrl == "https://ta.example.com/cache/search-thumb.jpg")
        #expect(result.channels.count == 1)
        #expect(result.channels[0].channelId == "ch-search")

        // Verify query param
        let url = MockURLProtocol.lastRequest?.url
        let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)
        let queryItem = components?.queryItems?.first { $0.name == "query" }
        #expect(queryItem?.value == "test query")
        authState.handleUnauthorized()
    }

    @Test func search_emptyResults_returnsEmptyArrays() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(json: ["results": nil] as [String: Any?])

        let result = try await repo.search(query: "nothing", page: 1)
        #expect(result.videos.isEmpty)
        #expect(result.channels.isEmpty)
        authState.handleUnauthorized()
    }

    @Test func search_401_throwsUnauthorized() async {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(statusCode: 401, json: ["detail": "Invalid token"])

        await #expect(throws: AppError.self) {
            _ = try await repo.search(query: "test", page: 1)
        }
        authState.handleUnauthorized()
    }
}
}
