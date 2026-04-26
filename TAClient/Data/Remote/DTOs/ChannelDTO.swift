import Foundation

struct ChannelSubscribeDTO: Encodable {
    let channelSubscribed: Bool

    enum CodingKeys: String, CodingKey {
        case channelSubscribed = "channel_subscribed"
    }
}

struct ChannelDTO: Decodable {
    let channelId: String?
    let channelName: String?
    let channelThumbUrl: String?
    let channelBannerUrl: String?
    let channelDescription: String?
    let channelSubscribed: Bool?
    let channelSubs: Int?

    enum CodingKeys: String, CodingKey {
        case channelId = "channel_id"
        case channelName = "channel_name"
        case channelThumbUrl = "channel_thumb_url"
        case channelBannerUrl = "channel_banner_url"
        case channelDescription = "channel_description"
        case channelSubscribed = "channel_subscribed"
        case channelSubs = "channel_subs"
    }
}
