import Foundation

final class PlaylistRepositoryImpl: PlaylistRepositoryProtocol {
    private let apiClient: APIClient
    private let authState: AuthState

    init(apiClient: APIClient, authState: AuthState) {
        self.apiClient = apiClient
        self.authState = authState
    }

    private var serverURL: String {
        authState.serverURL ?? ""
    }

    func getPlaylists(page: Int, type: String?) async throws -> PlaylistListResult {
        let response: PlaylistListResponseDTO = try await apiClient.request(
            endpoint: .playlistList(page: page, type: type)
        )
        let playlists = response.data?.compactMap { PlaylistMapper.map($0, serverURL: serverURL) } ?? []
        return PlaylistListResult(
            playlists: playlists,
            currentPage: response.paginate?.currentPage ?? page,
            lastPage: response.paginate?.lastPage ?? page
        )
    }

    func getPlaylist(id: String) async throws -> Playlist {
        let dto: PlaylistDTO = try await apiClient.request(endpoint: .playlistDetail(id: id))
        guard let playlist = PlaylistMapper.map(dto, serverURL: serverURL) else {
            throw AppError.decoding(underlying: nil)
        }
        return playlist
    }

    func getPlaylistVideos(playlistId: String, page: Int) async throws -> VideoListResult {
        let response: VideoListResponseDTO = try await apiClient.request(
            endpoint: .videoList(page: page, sort: "", order: "", watch: nil, channel: nil, vidType: nil, playlist: playlistId)
        )
        let videos = response.data?.compactMap { VideoMapper.map($0, serverURL: serverURL) } ?? []
        return VideoListResult(
            videos: videos,
            currentPage: response.paginate?.currentPage ?? page,
            lastPage: response.paginate?.lastPage ?? page,
            totalHits: response.paginate?.totalHits ?? videos.count
        )
    }

    func createCustomPlaylist(name: String) async throws -> Playlist {
        let dto: PlaylistDTO = try await apiClient.request(
            endpoint: .createCustomPlaylist,
            body: CreateCustomPlaylistDTO(playlistName: name)
        )
        guard let playlist = PlaylistMapper.map(dto, serverURL: serverURL) else {
            throw AppError.decoding(underlying: nil)
        }
        return playlist
    }

    func updateSubscription(playlistId: String, subscribed: Bool) async throws {
        try await apiClient.requestVoid(
            endpoint: .updatePlaylistSubscription(id: playlistId),
            body: PlaylistSubscriptionDTO(playlistSubscribed: subscribed)
        )
    }

    func addVideoToPlaylist(playlistId: String, videoId: String) async throws {
        try await apiClient.requestVoid(
            endpoint: .modifyCustomPlaylist(id: playlistId),
            body: PlaylistCustomActionDTO(action: "create", videoId: videoId)
        )
    }

    func removeVideoFromPlaylist(playlistId: String, videoId: String) async throws {
        try await apiClient.requestVoid(
            endpoint: .modifyCustomPlaylist(id: playlistId),
            body: PlaylistCustomActionDTO(action: "remove", videoId: videoId)
        )
    }

    func deletePlaylist(id: String, deleteVideos: Bool) async throws {
        try await apiClient.requestVoid(
            endpoint: .deletePlaylist(id: id, deleteVideos: deleteVideos)
        )
    }
}
