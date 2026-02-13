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

    // Videos
    case videoList(page: Int, sort: String, order: String, watch: String?, channel: String?)
    case videoDetail(id: String)
    case videoProgress(id: String)
    case deleteVideoProgress(id: String)
    case deleteVideo(id: String)
    case ignoreVideo(id: String)
    case videoComments(id: String)

    // Search
    case search(query: String, page: Int)

    // Channels
    case channelDetail(id: String)

    var path: String {
        switch self {
        case .login:
            return "/api/user/login/"
        case .token:
            return "/api/appsettings/token/"
        case .ping:
            return "/api/ping/"
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
        case .search:
            return "/api/search/"
        case .channelDetail(let id):
            return "/api/channel/\(id)/"
        }
    }

    var method: HTTPMethod {
        switch self {
        case .login, .videoProgress, .ignoreVideo:
            return .post
        case .deleteVideo, .deleteVideoProgress:
            return .delete
        default:
            return .get
        }
    }

    var queryItems: [URLQueryItem]? {
        switch self {
        case .videoList(let page, let sort, let order, let watch, let channel):
            var items = [
                URLQueryItem(name: "page", value: "\(page)"),
                URLQueryItem(name: "sort", value: sort),
                URLQueryItem(name: "order", value: order),
            ]
            if let watch, !watch.isEmpty {
                items.append(URLQueryItem(name: "watch", value: watch))
            }
            if let channel, !channel.isEmpty {
                items.append(URLQueryItem(name: "channel", value: channel))
            }
            return items
        case .search(let query, let page):
            return [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "page", value: "\(page)"),
            ]
        default:
            return nil
        }
    }
}
