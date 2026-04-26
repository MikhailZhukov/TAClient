import Foundation

enum Route: Hashable {
    case videoList
    case videoDetail(videoId: String)
    case search
    case channelDetail(channelId: String)
    case downloadQueue
    case playlistList
    case playlistDetail(playlistId: String)
    case settings
    case about
}
