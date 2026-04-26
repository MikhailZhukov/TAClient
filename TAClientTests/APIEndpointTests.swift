import Testing
import Foundation
@testable import TAClient

extension DataLayerSuite {
@Suite(.serialized) struct APIEndpointTests {

    // MARK: - Paths

    @Test func login_path() {
        #expect(APIEndpoint.login.path == "/api/user/login/")
    }

    @Test func token_path() {
        #expect(APIEndpoint.token.path == "/api/appsettings/token/")
    }

    @Test func ping_path() {
        #expect(APIEndpoint.ping.path == "/api/ping/")
    }

    @Test func videoList_path() {
        #expect(APIEndpoint.videoList(page: 1, sort: "date", order: "desc", watch: nil, channel: nil, vidType: nil).path == "/api/video/")
    }

    @Test func videoDetail_path() {
        #expect(APIEndpoint.videoDetail(id: "abc123").path == "/api/video/abc123/")
    }

    @Test func videoProgress_path() {
        #expect(APIEndpoint.videoProgress(id: "abc123").path == "/api/video/abc123/progress/")
    }

    @Test func deleteVideoProgress_path() {
        #expect(APIEndpoint.deleteVideoProgress(id: "abc123").path == "/api/video/abc123/progress/")
    }

    @Test func deleteVideo_path() {
        #expect(APIEndpoint.deleteVideo(id: "abc123").path == "/api/video/abc123/")
    }

    @Test func ignoreVideo_path() {
        #expect(APIEndpoint.ignoreVideo(id: "abc123").path == "/api/download/abc123/")
    }

    @Test func videoComments_path() {
        #expect(APIEndpoint.videoComments(id: "abc123").path == "/api/video/abc123/comment/")
    }

    @Test func search_path() {
        #expect(APIEndpoint.search(query: "test", page: 1).path == "/api/search/")
    }

    @Test func downloadList_path() {
        #expect(APIEndpoint.downloadList(page: 1, filter: "pending").path == "/api/download/")
    }

    @Test func updateDownloadStatus_path() {
        #expect(APIEndpoint.updateDownloadStatus(id: "abc123").path == "/api/download/abc123/")
    }

    @Test func deleteDownload_path() {
        #expect(APIEndpoint.deleteDownload(id: "abc123").path == "/api/download/abc123/")
    }

    @Test func addToDownloadQueue_path() {
        #expect(APIEndpoint.addToDownloadQueue.path == "/api/download/")
    }

    @Test func startDownload_path() {
        #expect(APIEndpoint.startDownload.path == "/api/task/by-name/download_pending/")
    }

    @Test func notifications_path() {
        #expect(APIEndpoint.notifications.path == "/api/notification/")
    }

    @Test func killTask_path() {
        #expect(APIEndpoint.killTask(id: "task-1").path == "/api/task/by-id/task-1/")
    }

    @Test func channelDetail_path() {
        #expect(APIEndpoint.channelDetail(id: "UCxyz").path == "/api/channel/UCxyz/")
    }

    @Test func setWatched_path() {
        #expect(APIEndpoint.setWatched.path == "/api/watched/")
    }

    @Test func setWatched_method() {
        #expect(APIEndpoint.setWatched.method == .post)
    }

    @Test func updateChannel_path() {
        #expect(APIEndpoint.updateChannel(id: "UCxyz").path == "/api/channel/UCxyz/")
    }

    @Test func updateChannel_method() {
        #expect(APIEndpoint.updateChannel(id: "UCxyz").method == .post)
    }

    // MARK: - HTTP Methods

    @Test func get_endpoints() {
        #expect(APIEndpoint.token.method == .get)
        #expect(APIEndpoint.ping.method == .get)
        #expect(APIEndpoint.videoList(page: 1, sort: "date", order: "desc", watch: nil, channel: nil, vidType: nil).method == .get)
        #expect(APIEndpoint.videoDetail(id: "x").method == .get)
        #expect(APIEndpoint.videoComments(id: "x").method == .get)
        #expect(APIEndpoint.search(query: "q", page: 1).method == .get)
        #expect(APIEndpoint.downloadList(page: 1, filter: "all").method == .get)
        #expect(APIEndpoint.notifications.method == .get)
        #expect(APIEndpoint.channelDetail(id: "x").method == .get)
    }

    @Test func post_endpoints() {
        #expect(APIEndpoint.login.method == .post)
        #expect(APIEndpoint.videoProgress(id: "x").method == .post)
        #expect(APIEndpoint.ignoreVideo(id: "x").method == .post)
        #expect(APIEndpoint.updateDownloadStatus(id: "x").method == .post)
        #expect(APIEndpoint.addToDownloadQueue.method == .post)
        #expect(APIEndpoint.startDownload.method == .post)
        #expect(APIEndpoint.killTask(id: "x").method == .post)
    }

    @Test func delete_endpoints() {
        #expect(APIEndpoint.deleteVideo(id: "x").method == .delete)
        #expect(APIEndpoint.deleteVideoProgress(id: "x").method == .delete)
        #expect(APIEndpoint.deleteDownload(id: "x").method == .delete)
    }

    // MARK: - Query Items

    @Test func videoList_queryItems_allParams() {
        let endpoint = APIEndpoint.videoList(page: 2, sort: "views", order: "asc", watch: "unwatched", channel: "UCxyz", vidType: nil)
        let items = endpoint.queryItems!
        #expect(items.contains(URLQueryItem(name: "page", value: "2")))
        #expect(items.contains(URLQueryItem(name: "sort", value: "views")))
        #expect(items.contains(URLQueryItem(name: "order", value: "asc")))
        #expect(items.contains(URLQueryItem(name: "watch", value: "unwatched")))
        #expect(items.contains(URLQueryItem(name: "channel", value: "UCxyz")))
    }

    @Test func videoList_queryItems_nilOptionals() {
        let endpoint = APIEndpoint.videoList(page: 1, sort: "date", order: "desc", watch: nil, channel: nil, vidType: nil)
        let items = endpoint.queryItems!
        #expect(items.count == 3)
        #expect(!items.contains { $0.name == "watch" })
        #expect(!items.contains { $0.name == "channel" })
    }

    @Test func videoList_queryItems_emptyOptionals() {
        let endpoint = APIEndpoint.videoList(page: 1, sort: "date", order: "desc", watch: "", channel: "", vidType: nil)
        let items = endpoint.queryItems!
        #expect(items.count == 3)
        #expect(!items.contains { $0.name == "watch" })
        #expect(!items.contains { $0.name == "channel" })
    }

    @Test func search_queryItems() {
        let endpoint = APIEndpoint.search(query: "hello world", page: 3)
        let items = endpoint.queryItems!
        #expect(items.contains(URLQueryItem(name: "query", value: "hello world")))
        #expect(items.contains(URLQueryItem(name: "page", value: "3")))
    }

    @Test func downloadList_queryItems() {
        let endpoint = APIEndpoint.downloadList(page: 2, filter: "pending")
        let items = endpoint.queryItems!
        #expect(items.contains(URLQueryItem(name: "filter", value: "pending")))
        #expect(items.contains(URLQueryItem(name: "page", value: "2")))
    }

    @Test func endpointsWithoutQueryItems_returnNil() {
        #expect(APIEndpoint.login.queryItems == nil)
        #expect(APIEndpoint.token.queryItems == nil)
        #expect(APIEndpoint.ping.queryItems == nil)
        #expect(APIEndpoint.videoDetail(id: "x").queryItems == nil)
        #expect(APIEndpoint.videoProgress(id: "x").queryItems == nil)
        #expect(APIEndpoint.deleteVideoProgress(id: "x").queryItems == nil)
        #expect(APIEndpoint.deleteVideo(id: "x").queryItems == nil)
        #expect(APIEndpoint.ignoreVideo(id: "x").queryItems == nil)
        #expect(APIEndpoint.videoComments(id: "x").queryItems == nil)
        #expect(APIEndpoint.updateDownloadStatus(id: "x").queryItems == nil)
        #expect(APIEndpoint.deleteDownload(id: "x").queryItems == nil)
        #expect(APIEndpoint.addToDownloadQueue.queryItems == nil)
        #expect(APIEndpoint.startDownload.queryItems == nil)
        #expect(APIEndpoint.notifications.queryItems == nil)
        #expect(APIEndpoint.killTask(id: "x").queryItems == nil)
        #expect(APIEndpoint.channelDetail(id: "x").queryItems == nil)
    }
}
}
