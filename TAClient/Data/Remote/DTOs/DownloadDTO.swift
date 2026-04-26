import Foundation

struct DownloadListResponseDTO: Decodable {
    let data: [DownloadItemDTO]?
    let paginate: PaginationDTO?
}

struct DownloadItemDTO: Decodable {
    let youtubeId: String?
    let title: String?
    let channelName: String?
    let channelId: String?
    let duration: String?
    let published: String?
    let status: String?
    let message: String?
    let vidThumbUrl: String?
    let vidType: String?
    let timestamp: Int?

    enum CodingKeys: String, CodingKey {
        case youtubeId = "youtube_id"
        case title, duration, published, status, message, timestamp
        case channelName = "channel_name"
        case channelId = "channel_id"
        case vidThumbUrl = "vid_thumb_url"
        case vidType = "vid_type"
    }
}

struct DownloadStatusDTO: Encodable {
    let status: String
}

struct AddToDownloadListDTO: Encodable {
    let data: [AddDownloadItemDTO]
}

struct AddDownloadItemDTO: Encodable {
    let youtubeId: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case youtubeId = "youtube_id"
        case status
    }
}
