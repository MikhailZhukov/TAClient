import Foundation

final class VideoRepositoryImpl: VideoRepositoryProtocol {
    private let apiClient: APIClient
    private let authState: AuthState

    init(apiClient: APIClient, authState: AuthState) {
        self.apiClient = apiClient
        self.authState = authState
    }

    private var serverURL: String {
        authState.serverURL ?? ""
    }

    func getVideos(page: Int, sort: String, order: String, watch: String?, channel: String?, vidType: String?) async throws -> VideoListResult {
        let response: VideoListResponseDTO = try await apiClient.request(
            endpoint: .videoList(page: page, sort: sort, order: order, watch: watch, channel: channel, vidType: vidType)
        )

        let videos = response.data?.compactMap { VideoMapper.map($0, serverURL: serverURL) } ?? []
        return VideoListResult(
            videos: videos,
            currentPage: response.paginate?.currentPage ?? page,
            lastPage: response.paginate?.lastPage ?? page,
            totalHits: response.paginate?.totalHits ?? videos.count
        )
    }

    func getVideo(id: String) async throws -> Video {
        let dto: VideoDTO = try await apiClient.request(endpoint: .videoDetail(id: id))
        guard let video = VideoMapper.map(dto, serverURL: serverURL) else {
            throw AppError.decoding(underlying: nil)
        }
        return video
    }

    func updateProgress(videoId: String, position: Double) async throws {
        try await apiClient.requestVoid(
            endpoint: .videoProgress(id: videoId),
            body: VideoProgressDTO(position: position)
        )
    }

    func deleteProgress(videoId: String) async throws {
        try await apiClient.requestVoid(endpoint: .deleteVideoProgress(id: videoId))
    }

    func deleteVideo(id: String) async throws {
        try await apiClient.requestVoid(endpoint: .deleteVideo(id: id))
    }

    func ignoreVideo(id: String) async throws {
        try await apiClient.requestVoid(
            endpoint: .ignoreVideo(id: id),
            body: IgnoreVideoDTO(status: "ignore-force")
        )
    }

    func getComments(videoId: String) async throws -> [Comment] {
        let dtos: [CommentDTO] = try await apiClient.request(endpoint: .videoComments(id: videoId))
        return dtos.compactMap { CommentMapper.map($0, serverURL: serverURL) }
    }

    func setWatched(videoId: String, isWatched: Bool) async throws {
        try await apiClient.requestVoid(
            endpoint: .setWatched,
            body: WatchedDTO(id: videoId, isWatched: isWatched)
        )
    }

    func getSimilarVideos(videoId: String) async throws -> [Video] {
        let dtos: [VideoDTO] = try await apiClient.request(endpoint: .similarVideos(id: videoId))
        return dtos.compactMap { VideoMapper.map($0, serverURL: serverURL) }
    }
}
