import Foundation

struct SearchResponseDTO: Decodable {
    let results: SearchResultsDTO?
}

struct SearchResultsDTO: Decodable {
    let videoResults: [VideoDTO]?
    let channelResults: [ChannelDTO]?

    enum CodingKeys: String, CodingKey {
        case videoResults = "video_results"
        case channelResults = "channel_results"
    }
}
