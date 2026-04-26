import Foundation

final class ChannelRepositoryImpl: ChannelRepositoryProtocol {
    private let apiClient: APIClient
    private let authState: AuthState

    init(apiClient: APIClient, authState: AuthState) {
        self.apiClient = apiClient
        self.authState = authState
    }

    private var serverURL: String {
        authState.serverURL ?? ""
    }

    func getChannel(id: String) async throws -> Channel {
        let dto: ChannelDTO = try await apiClient.request(endpoint: .channelDetail(id: id))
        guard let channel = ChannelMapper.map(dto, serverURL: serverURL) else {
            throw AppError.decoding(underlying: nil)
        }
        return channel
    }

    func setSubscribed(channelId: String, subscribed: Bool) async throws {
        try await apiClient.requestVoid(
            endpoint: .updateChannel(id: channelId),
            body: ChannelSubscribeDTO(channelSubscribed: subscribed)
        )
    }
}
