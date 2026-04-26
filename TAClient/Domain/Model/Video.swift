import Foundation

struct Video: Identifiable, Hashable {
    var id: String { youtubeId }

    let youtubeId: String
    let title: String
    let description: String?
    let published: String
    let publishedShort: String
    let downloaded: String
    let downloadedShort: String
    let channelName: String
    let channelId: String
    let channelThumbUrl: String?
    let thumbUrl: String
    let mediaUrl: String
    let duration: Int
    let durationStr: String
    var watched: Bool
    let progress: Double
    let position: Double
    let viewCount: Int
    let likeCount: Int
    let mediaSize: Int64
    let vidType: String
    let category: [String]
    let tags: [String]
    let streams: [StreamInfo]
    let sponsorblock: [SponsorBlockSegment]
    var playlists: [String]
}

struct StreamInfo: Hashable {
    let type: String
    let codec: String
    let bitrate: Int
    let width: Int?
    let height: Int?
}
