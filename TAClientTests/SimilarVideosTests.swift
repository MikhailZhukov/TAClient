import Foundation
import SwiftUI
import Testing
@testable import TAClient

// MARK: - ViewModel Tests

struct SimilarVideosViewModelTests {

    private func makeSUT(
        videoId: String = "test-video-id",
        videoRepo: MockVideoRepository = MockVideoRepository()
    ) -> (VideoDetailViewModel, AppRouter) {
        let keychain = KeychainService()
        keychain.clearAll()
        let authState = AuthState(keychainService: keychain)
        let router = AppRouter(authState: authState)
        let vm = VideoDetailViewModel(videoId: videoId, videoRepository: videoRepo, authState: authState, router: router)
        return (vm, router)
    }

    @Test func loadSimilarVideos_success_populatesVideos() async {
        let repo = MockVideoRepository()
        repo.getSimilarVideosHandler = { _ in
            [
                TestData.video(youtubeId: "sim-1", title: "Similar 1"),
                TestData.video(youtubeId: "sim-2", title: "Similar 2"),
                TestData.video(youtubeId: "sim-3", title: "Similar 3"),
            ]
        }
        let (vm, _) = makeSUT(videoRepo: repo)

        await vm.loadSimilarVideos()

        #expect(vm.similarVideos.count == 3)
        #expect(vm.similarVideos[0].youtubeId == "sim-1")
        #expect(vm.similarVideos[2].title == "Similar 3")
        #expect(vm.isLoadingSimilar == false)
    }

    @Test func loadSimilarVideos_empty_returnsEmpty() async {
        let repo = MockVideoRepository()
        repo.getSimilarVideosHandler = { _ in [] }
        let (vm, _) = makeSUT(videoRepo: repo)

        await vm.loadSimilarVideos()

        #expect(vm.similarVideos.isEmpty)
        #expect(vm.isLoadingSimilar == false)
    }

    @Test func loadSimilarVideos_error_silentlyCaught() async {
        let repo = MockVideoRepository()
        repo.getSimilarVideosHandler = { _ in
            throw AppError.network(underlying: nil)
        }
        let (vm, _) = makeSUT(videoRepo: repo)

        await vm.loadSimilarVideos()

        #expect(vm.similarVideos.isEmpty)
        #expect(vm.isLoadingSimilar == false)
    }

    @Test func loadSimilarVideos_onlyLoadsOnce() async {
        var callCount = 0
        let repo = MockVideoRepository()
        repo.getSimilarVideosHandler = { _ in
            callCount += 1
            return [TestData.video(youtubeId: "sim-1")]
        }
        let (vm, _) = makeSUT(videoRepo: repo)

        await vm.loadSimilarVideos()
        await vm.loadSimilarVideos()

        #expect(callCount == 1)
        #expect(vm.similarVideos.count == 1)
    }

    @Test func loadSimilarVideos_passesCorrectVideoId() async {
        var capturedVideoId: String?
        let repo = MockVideoRepository()
        repo.getSimilarVideosHandler = { videoId in
            capturedVideoId = videoId
            return []
        }
        let (vm, _) = makeSUT(videoId: "my-video-123", videoRepo: repo)

        await vm.loadSimilarVideos()

        #expect(capturedVideoId == "my-video-123")
    }

    @Test func navigateToVideo_appendsRoute() {
        let (vm, router) = makeSUT()
        vm.navigateToVideo("sim-1")
        #expect(router.path.count == 1)
    }
}

// MARK: - API Endpoint Tests

struct SimilarVideosEndpointTests {

    @Test func endpoint_path() {
        let endpoint = APIEndpoint.similarVideos(id: "abc123")
        #expect(endpoint.path.contains("/api/video/abc123/similar"))
    }

    @Test func endpoint_method_isGet() {
        let endpoint = APIEndpoint.similarVideos(id: "abc123")
        #expect(endpoint.method == .get)
    }

    @Test func endpoint_noQueryItems() {
        let endpoint = APIEndpoint.similarVideos(id: "abc123")
        #expect(endpoint.queryItems == nil)
    }
}

// MARK: - Repository Tests

extension DataLayerSuite {
@Suite(.serialized) struct SimilarVideosRepositoryTests {

    init() {
        MockResponse.tearDown()
    }

    private func makeRepo() -> (VideoRepositoryImpl, AuthState) {
        let (client, authState) = MockResponse.makeAPIClient()
        let repo = VideoRepositoryImpl(apiClient: client, authState: authState)
        return (repo, authState)
    }

    @Test func getSimilarVideos_success_mapsVideos() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(json: [
            [
                "youtube_id": "sim-1",
                "title": "Similar Video 1",
                "vid_thumb_url": "/cache/sim1.jpg",
                "media_url": "/cache/sim1.mp4",
                "player": ["watched": false, "duration": 300, "duration_str": "5:00", "progress": 0.0, "position": 0.0],
                "stats": ["view_count": 500, "like_count": 25],
            ],
            [
                "youtube_id": "sim-2",
                "title": "Similar Video 2",
                "vid_thumb_url": "/cache/sim2.jpg",
                "media_url": "/cache/sim2.mp4",
                "player": ["watched": true, "duration": 600, "duration_str": "10:00", "progress": 100.0, "position": 600.0],
                "stats": ["view_count": 1000, "like_count": 50],
            ],
        ] as [Any])

        let videos = try await repo.getSimilarVideos(videoId: "test-vid")

        #expect(videos.count == 2)
        #expect(videos[0].youtubeId == "sim-1")
        #expect(videos[0].title == "Similar Video 1")
        #expect(videos[0].thumbUrl == "https://ta.example.com/cache/sim1.jpg")
        #expect(videos[1].watched == true)
        #expect(videos[1].viewCount == 1000)

        // Verify correct endpoint
        let url = MockURLProtocol.lastRequest?.url?.path ?? ""
        #expect(url.contains("/api/video/test-vid/similar"))

        authState.handleUnauthorized()
    }

    @Test func getSimilarVideos_emptyArray_returnsEmpty() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(json: [] as [Any])

        let videos = try await repo.getSimilarVideos(videoId: "test-vid")

        #expect(videos.isEmpty)
        authState.handleUnauthorized()
    }

    @Test func getSimilarVideos_invalidItems_filtered() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(json: [
            ["youtube_id": "valid", "title": "Valid Video"],
            ["youtube_id": nil, "title": "Missing ID"],  // filtered
            ["youtube_id": "valid2", "title": nil],       // filtered
        ] as [Any])

        let videos = try await repo.getSimilarVideos(videoId: "test-vid")

        #expect(videos.count == 1)
        #expect(videos[0].youtubeId == "valid")
        authState.handleUnauthorized()
    }

    @Test func getSimilarVideos_401_throwsUnauthorized() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(statusCode: 401, json: ["detail": "Invalid token."])

        do {
            _ = try await repo.getSimilarVideos(videoId: "test-vid")
            #expect(Bool(false), "Expected error")
        } catch {
            #expect(error is AppError)
        }
        authState.handleUnauthorized()
    }
}
}
