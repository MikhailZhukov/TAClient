import Foundation

struct PlaylistListResponseDTO: Decodable {
    let data: [PlaylistDTO]?
    let paginate: PaginationDTO?
}

struct PlaylistDTO: Decodable {
    let playlistId: String?
    let playlistName: String?
    let playlistChannel: String?
    let playlistChannelId: String?
    let playlistType: String?
    let playlistSubscribed: Bool?
    let playlistThumbnail: String?
    let playlistDescription: String?
    let playlistEntries: [PlaylistEntryDTO]?

    enum CodingKeys: String, CodingKey {
        case playlistId = "playlist_id"
        case playlistName = "playlist_name"
        case playlistChannel = "playlist_channel"
        case playlistChannelId = "playlist_channel_id"
        case playlistType = "playlist_type"
        case playlistSubscribed = "playlist_subscribed"
        case playlistThumbnail = "playlist_thumbnail"
        case playlistDescription = "playlist_description"
        case playlistEntries = "playlist_entries"
    }
}

struct PlaylistEntryDTO: Decodable {
    let youtubeId: String?
    let title: String?
    let uploader: String?
    let idx: Int?
    let downloaded: Bool?

    enum CodingKeys: String, CodingKey {
        case youtubeId = "youtube_id"
        case title, uploader, idx, downloaded
    }
}

// MARK: - Request DTOs

struct CreateCustomPlaylistDTO: Encodable {
    let playlistName: String

    enum CodingKeys: String, CodingKey {
        case playlistName = "playlist_name"
    }
}

struct PlaylistSubscriptionDTO: Encodable {
    let playlistSubscribed: Bool

    enum CodingKeys: String, CodingKey {
        case playlistSubscribed = "playlist_subscribed"
    }
}

struct PlaylistCustomActionDTO: Encodable {
    let action: String
    let videoId: String

    enum CodingKeys: String, CodingKey {
        case action
        case videoId = "video_id"
    }
}
