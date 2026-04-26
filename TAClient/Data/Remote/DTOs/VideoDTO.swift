import Foundation

struct VideoListResponseDTO: Decodable {
    let data: [VideoDTO]?
    let paginate: PaginationDTO?
}

struct VideoDTO: Decodable {
    let youtubeId: String?
    let title: String?
    let description: String?
    let published: String?
    let dateDownloaded: Int?
    let active: Bool?
    let channel: ChannelInfoDTO?
    let vidThumbUrl: String?
    let mediaUrl: String?
    let mediaSize: Int64?
    let player: PlayerDTO?
    let stats: StatsDTO?
    let vidType: String?
    let category: [String]?
    let tags: [String]?
    let streams: [StreamDTO]?
    let sponsorblock: SponsorBlockDTO?
    let playlist: [String]?

    enum CodingKeys: String, CodingKey {
        case youtubeId = "youtube_id"
        case title, description, published, active, channel, player, stats, category, tags, streams, sponsorblock, playlist
        case dateDownloaded = "date_downloaded"
        case vidThumbUrl = "vid_thumb_url"
        case mediaUrl = "media_url"
        case mediaSize = "media_size"
        case vidType = "vid_type"
    }
}

struct ChannelInfoDTO: Decodable {
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

struct PlayerDTO: Decodable {
    let watched: Bool?
    let duration: Int?
    let durationStr: String?
    let progress: Double?
    let position: Double?

    enum CodingKeys: String, CodingKey {
        case watched, duration, progress, position
        case durationStr = "duration_str"
    }
}

struct StatsDTO: Decodable {
    let viewCount: Int?
    let likeCount: Int?
    let dislikeCount: Int?
    let averageRating: Double?

    enum CodingKeys: String, CodingKey {
        case viewCount = "view_count"
        case likeCount = "like_count"
        case dislikeCount = "dislike_count"
        case averageRating = "average_rating"
    }
}

struct StreamDTO: Decodable {
    let type: String?
    let index: Int?
    let codec: String?
    let bitrate: Int?
    let width: Int?
    let height: Int?
}

struct VideoProgressDTO: Encodable {
    let position: Double
}

struct IgnoreVideoDTO: Encodable {
    let status: String
}

struct WatchedDTO: Encodable {
    let id: String
    let isWatched: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case isWatched = "is_watched"
    }
}
