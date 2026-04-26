import Foundation

enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case delete = "DELETE"
}

enum APIEndpoint {
    // Auth
    case login
    case token
    case ping
    case userAccount

    // Videos
    case videoList(page: Int, sort: String, order: String, watch: String?, channel: String?, vidType: String?, playlist: String? = nil)
    case videoDetail(id: String)
    case videoProgress(id: String)
    case deleteVideoProgress(id: String)
    case deleteVideo(id: String)
    case ignoreVideo(id: String)
    case videoComments(id: String)
    case similarVideos(id: String)

    // Search
    case search(query: String, page: Int)

    // Downloads
    case downloadList(page: Int, filter: String)
    case updateDownloadStatus(id: String)
    case deleteDownload(id: String)
    case addToDownloadQueue
    case startDownload
    case rescanSubscriptions
    case notifications
    case killTask(id: String)

    // Watched
    case setWatched

    // Playlists
    case playlistList(page: Int, type: String?)
    case playlistDetail(id: String)
    case createCustomPlaylist
    case modifyCustomPlaylist(id: String)
    case updatePlaylistSubscription(id: String)
    case deletePlaylist(id: String, deleteVideos: Bool)

    // Channels
    case channelDetail(id: String)
    case updateChannel(id: String)

    var path: String {
        switch self {
        case .login:
            return "/api/user/login/"
        case .token:
            return "/api/appsettings/token/"
        case .ping:
            return "/api/ping/"
        case .userAccount:
            return "/api/user/account/"
        case .videoList:
            return "/api/video/"
        case .videoDetail(let id):
            return "/api/video/\(id)/"
        case .videoProgress(let id):
            return "/api/video/\(id)/progress/"
        case .deleteVideoProgress(let id):
            return "/api/video/\(id)/progress/"
        case .deleteVideo(let id):
            return "/api/video/\(id)/"
        case .ignoreVideo(let id):
            return "/api/download/\(id)/"
        case .videoComments(let id):
            return "/api/video/\(id)/comment/"
        case .similarVideos(let id):
            return "/api/video/\(id)/similar/"
        case .downloadList:
            return "/api/download/"
        case .updateDownloadStatus(let id):
            return "/api/download/\(id)/"
        case .deleteDownload(let id):
            return "/api/download/\(id)/"
        case .addToDownloadQueue:
            return "/api/download/"
        case .startDownload:
            return "/api/task/by-name/download_pending/"
        case .rescanSubscriptions:
            return "/api/task/by-name/update_subscribed/"
        case .notifications:
            return "/api/notification/"
        case .killTask(let id):
            return "/api/task/by-id/\(id)/"
        case .search:
            return "/api/search/"
        case .playlistList:
            return "/api/playlist/"
        case .playlistDetail(let id):
            return "/api/playlist/\(id)/"
        case .createCustomPlaylist:
            return "/api/playlist/custom/"
        case .modifyCustomPlaylist(let id):
            return "/api/playlist/custom/\(id)/"
        case .updatePlaylistSubscription(let id):
            return "/api/playlist/\(id)/"
        case .deletePlaylist(let id, _):
            return "/api/playlist/\(id)/"
        case .setWatched:
            return "/api/watched/"
        case .channelDetail(let id):
            return "/api/channel/\(id)/"
        case .updateChannel(let id):
            return "/api/channel/\(id)/"
        }
    }

    var method: HTTPMethod {
        switch self {
        case .login, .videoProgress, .ignoreVideo, .updateDownloadStatus, .addToDownloadQueue, .startDownload, .rescanSubscriptions, .killTask, .setWatched, .updateChannel, .createCustomPlaylist, .modifyCustomPlaylist, .updatePlaylistSubscription:
            return .post
        case .deleteVideo, .deleteVideoProgress, .deleteDownload, .deletePlaylist:
            return .delete
        default:
            return .get
        }
    }

    var queryItems: [URLQueryItem]? {
        switch self {
        case .videoList(let page, let sort, let order, let watch, let channel, let vidType, let playlist):
            var items = [URLQueryItem(name: "page", value: "\(page)")]
            if !sort.isEmpty {
                items.append(URLQueryItem(name: "sort", value: sort))
            }
            if !order.isEmpty {
                items.append(URLQueryItem(name: "order", value: order))
            }
            if let watch, !watch.isEmpty {
                items.append(URLQueryItem(name: "watch", value: watch))
            }
            if let channel, !channel.isEmpty {
                items.append(URLQueryItem(name: "channel", value: channel))
            }
            if let vidType, !vidType.isEmpty {
                items.append(URLQueryItem(name: "type", value: vidType))
            }
            if let playlist, !playlist.isEmpty {
                items.append(URLQueryItem(name: "playlist", value: playlist))
            }
            return items
        case .downloadList(let page, let filter):
            return [
                URLQueryItem(name: "filter", value: filter),
                URLQueryItem(name: "page", value: "\(page)"),
            ]
        case .search(let query, let page):
            return [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "page", value: "\(page)"),
            ]
        case .playlistList(let page, let type):
            var items = [URLQueryItem(name: "page", value: "\(page)")]
            if let type, !type.isEmpty {
                items.append(URLQueryItem(name: "type", value: type))
            }
            return items
        case .deletePlaylist(_, let deleteVideos):
            return deleteVideos ? [URLQueryItem(name: "delete_videos", value: "true")] : nil
        default:
            return nil
        }
    }
}
