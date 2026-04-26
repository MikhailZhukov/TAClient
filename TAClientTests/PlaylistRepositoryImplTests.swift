import Testing
import Foundation
@testable import TAClient

extension DataLayerSuite {
@Suite(.serialized) struct PlaylistRepositoryImplTests {

    init() {
        MockResponse.tearDown()
    }

    private func makeRepo() -> (PlaylistRepositoryImpl, AuthState) {
        let (client, authState) = MockResponse.makeAPIClient()
        let repo = PlaylistRepositoryImpl(apiClient: client, authState: authState)
        return (repo, authState)
    }

    // MARK: - getPlaylists

    @Test func getPlaylists_success_mapsPagination() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(json: [
            "data": [
                [
                    "playlist_id": "pl1",
                    "playlist_name": "My Playlist",
                    "playlist_channel": "Creator",
                    "playlist_channel_id": "ch1",
                    "playlist_type": "regular",
                    "playlist_subscribed": true,
                    "playlist_thumbnail": "/cache/pl-thumb.jpg",
                    "playlist_entries": [] as [Any],
                ]
            ],
            "paginate": [
                "current_page": 1,
                "last_page": 3,
            ]
        ] as [String: Any])

        let result = try await repo.getPlaylists(page: 1, type: nil)

        #expect(result.currentPage == 1)
        #expect(result.lastPage == 3)
        #expect(result.playlists.count == 1)
        #expect(result.playlists[0].playlistId == "pl1")
        #expect(result.playlists[0].playlistThumbnail == "https://ta.example.com/cache/pl-thumb.jpg")
        authState.handleUnauthorized()
    }

    @Test func getPlaylists_withType_sendsQueryParam() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(json: ["data": [] as [Any], "paginate": ["current_page": 1, "last_page": 1]] as [String: Any])

        _ = try await repo.getPlaylists(page: 1, type: "custom")

        let url = MockURLProtocol.lastRequest?.url?.absoluteString ?? ""
        #expect(url.contains("type=custom"))
        authState.handleUnauthorized()
    }

    @Test func getPlaylists_401_throwsUnauthorized() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(statusCode: 401, json: ["detail": "Invalid token."])

        do {
            _ = try await repo.getPlaylists(page: 1, type: nil)
            #expect(Bool(false), "Expected error")
        } catch {
            #expect(error is AppError)
        }
        authState.handleUnauthorized()
    }

    // MARK: - getPlaylist

    @Test func getPlaylist_success_mapsFields() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(json: [
            "playlist_id": "pl1",
            "playlist_name": "Detail Playlist",
            "playlist_channel": "Channel",
            "playlist_channel_id": "ch1",
            "playlist_type": "custom",
            "playlist_subscribed": false,
            "playlist_thumbnail": "/thumb.jpg",
            "playlist_description": "A description",
            "playlist_entries": [
                ["youtube_id": "v1", "title": "Video 1", "idx": 0, "downloaded": true],
                ["youtube_id": "v2", "title": "Video 2", "idx": 1, "downloaded": false],
            ],
        ] as [String: Any])

        let playlist = try await repo.getPlaylist(id: "pl1")

        #expect(playlist.playlistId == "pl1")
        #expect(playlist.playlistType == .custom)
        #expect(playlist.playlistDescription == "A description")
        #expect(playlist.playlistEntries.count == 2)
        #expect(playlist.playlistEntries[0].downloaded == true)

        let url = MockURLProtocol.lastRequest?.url?.path ?? ""
        #expect(url.contains("/api/playlist/pl1"))
        authState.handleUnauthorized()
    }

    // MARK: - getPlaylistVideos

    @Test func getPlaylistVideos_sendsPlaylistParam() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(json: [
            "data": [
                ["youtube_id": "vid1", "title": "Video 1"],
            ],
            "paginate": ["current_page": 1, "last_page": 1, "total_hits": 1],
        ] as [String: Any])

        let result = try await repo.getPlaylistVideos(playlistId: "pl1", page: 1)

        let url = MockURLProtocol.lastRequest?.url?.absoluteString ?? ""
        #expect(url.contains("playlist=pl1"))
        #expect(result.videos.count == 1)
        authState.handleUnauthorized()
    }

    // MARK: - createCustomPlaylist

    @Test func createCustomPlaylist_sendsCorrectBody() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(json: [
            "playlist_id": "new-pl",
            "playlist_name": "My New",
            "playlist_type": "custom",
            "playlist_entries": [] as [Any],
        ] as [String: Any])

        let playlist = try await repo.createCustomPlaylist(name: "My New")

        #expect(playlist.playlistId == "new-pl")
        #expect(playlist.playlistType == .custom)

        let url = MockURLProtocol.lastRequest?.url?.path ?? ""
        #expect(url.contains("/api/playlist/custom"))
        #expect(MockURLProtocol.lastRequest?.httpMethod == "POST")
        authState.handleUnauthorized()
    }

    // MARK: - updateSubscription

    @Test func updateSubscription_sendsPost() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(json: ["status": "ok"])

        try await repo.updateSubscription(playlistId: "pl1", subscribed: false)

        let url = MockURLProtocol.lastRequest?.url?.path ?? ""
        #expect(url.contains("/api/playlist/pl1"))
        #expect(MockURLProtocol.lastRequest?.httpMethod == "POST")
        authState.handleUnauthorized()
    }

    // MARK: - addVideoToPlaylist

    @Test func addVideoToPlaylist_sendsCorrectAction() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(json: ["status": "ok"])

        try await repo.addVideoToPlaylist(playlistId: "pl1", videoId: "vid1")

        let url = MockURLProtocol.lastRequest?.url?.path ?? ""
        #expect(url.contains("/api/playlist/custom/pl1"))
        #expect(MockURLProtocol.lastRequest?.httpMethod == "POST")
        authState.handleUnauthorized()
    }

    // MARK: - removeVideoFromPlaylist

    @Test func removeVideoFromPlaylist_sendsRemoveAction() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(json: ["status": "ok"])

        try await repo.removeVideoFromPlaylist(playlistId: "pl1", videoId: "vid1")

        let url = MockURLProtocol.lastRequest?.url?.path ?? ""
        #expect(url.contains("/api/playlist/custom/pl1"))
        authState.handleUnauthorized()
    }

    // MARK: - deletePlaylist

    @Test func deletePlaylist_sendsDelete() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(json: [:] as [String: Any])

        try await repo.deletePlaylist(id: "pl1", deleteVideos: false)

        let url = MockURLProtocol.lastRequest?.url?.path ?? ""
        #expect(url.contains("/api/playlist/pl1"))
        #expect(MockURLProtocol.lastRequest?.httpMethod == "DELETE")
        authState.handleUnauthorized()
    }

    @Test func deletePlaylist_withVideos_sendsQueryParam() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(json: [:] as [String: Any])

        try await repo.deletePlaylist(id: "pl1", deleteVideos: true)

        let url = MockURLProtocol.lastRequest?.url?.absoluteString ?? ""
        #expect(url.contains("delete_videos=true"))
        authState.handleUnauthorized()
    }
}
}
