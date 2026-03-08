import Foundation

struct DownloadItem: Identifiable, Hashable {
    var id: String { youtubeId }

    let youtubeId: String
    let title: String
    let channelName: String
    let channelId: String
    let duration: String
    let published: String
    let status: String
    let message: String?
    let thumbUrl: String?
    let vidType: String
    let timestamp: Int
}

struct DownloadListResult {
    let items: [DownloadItem]
    let currentPage: Int
    let lastPage: Int
}
