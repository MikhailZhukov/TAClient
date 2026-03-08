import Foundation

final class SearchRepositoryImpl: SearchRepositoryProtocol {
    private let apiClient: APIClient
    private let authState: AuthState

    init(apiClient: APIClient, authState: AuthState) {
        self.apiClient = apiClient
        self.authState = authState
    }

    private var serverURL: String {
        authState.serverURL ?? ""
    }

    func search(query: String, page: Int) async throws -> SearchResult {
        let response: SearchResponseDTO = try await apiClient.request(
            endpoint: .search(query: query, page: page)
        )

        let videos = response.results?.videoResults?.compactMap { VideoMapper.map($0, serverURL: serverURL) } ?? []
        let channels = response.results?.channelResults?.compactMap { ChannelMapper.map($0, serverURL: serverURL) } ?? []

        return SearchResult(videos: videos, channels: channels)
    }
}
