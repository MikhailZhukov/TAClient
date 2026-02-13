import Foundation

enum Route: Hashable {
    case videoList
    case videoDetail(videoId: String)
    case search
    case channelDetail(channelId: String)
}
