import Foundation

protocol ChannelRepositoryProtocol {
    func getChannel(id: String) async throws -> Channel
    func setSubscribed(channelId: String, subscribed: Bool) async throws
}
