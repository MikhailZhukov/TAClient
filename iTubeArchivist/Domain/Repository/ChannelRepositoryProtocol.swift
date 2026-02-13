import Foundation

protocol ChannelRepositoryProtocol {
    func getChannel(id: String) async throws -> Channel
}
