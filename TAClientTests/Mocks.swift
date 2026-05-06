import Foundation
@testable import TAClient

// MARK: - Mock Repositories

final class MockAuthRepository: AuthRepositoryProtocol {
    var loginHandler: (String, String, String) async throws -> Void = { _, _, _ in }
    var pingHandler: () async throws -> Bool = { true }
    var fetchUserAccountHandler: () async throws -> Void = {}
    var logoutHandler: () -> Void = {}

    func login(serverURL: String, username: String, password: String) async throws {
        try await loginHandler(serverURL, username, password)
    }

    func ping() async throws -> Bool {
        try await pingHandler()
    }

    func fetchUserAccount() async throws {
        try await fetchUserAccountHandler()
    }

    func logout() {
        logoutHandler()
    }
}

final class MockVideoRepository: VideoRepositoryProtocol {
    var getVideosHandler: (Int, String, String, String?, String?, String?) async throws -> VideoListResult = { _, _, _, _, _, _ in
        VideoListResult(videos: [], currentPage: 1, lastPage: 1, totalHits: 0)
    }
    var getVideoHandler: (String) async throws -> Video = { _ in TestData.video() }
    var updateProgressHandler: (String, Double) async throws -> Void = { _, _ in }
    var deleteProgressHandler: (String) async throws -> Void = { _ in }
    var deleteVideoHandler: (String) async throws -> Void = { _ in }
    var ignoreVideoHandler: (String) async throws -> Void = { _ in }
    var getCommentsHandler: (String) async throws -> [Comment] = { _ in [] }
    var setWatchedHandler: (String, Bool) async throws -> Void = { _, _ in }
    var getSimilarVideosHandler: (String) async throws -> [Video] = { _ in [] }

    func getVideos(page: Int, sort: String, order: String, watch: String?, channel: String?, vidType: String?) async throws -> VideoListResult {
        try await getVideosHandler(page, sort, order, watch, channel, vidType)
    }

    func getVideo(id: String) async throws -> Video {
        try await getVideoHandler(id)
    }

    func updateProgress(videoId: String, position: Double) async throws {
        try await updateProgressHandler(videoId, position)
    }

    func deleteProgress(videoId: String) async throws {
        try await deleteProgressHandler(videoId)
    }

    func deleteVideo(id: String) async throws {
        try await deleteVideoHandler(id)
    }

    func ignoreVideo(id: String) async throws {
        try await ignoreVideoHandler(id)
    }

    func getComments(videoId: String) async throws -> [Comment] {
        try await getCommentsHandler(videoId)
    }

    func setWatched(videoId: String, isWatched: Bool) async throws {
        try await setWatchedHandler(videoId, isWatched)
    }

    func getSimilarVideos(videoId: String) async throws -> [Video] {
        try await getSimilarVideosHandler(videoId)
    }
}

final class MockSearchRepository: SearchRepositoryProtocol {
    var searchHandler: (String, Int) async throws -> SearchResult = { _, _ in
        SearchResult(videos: [], channels: [])
    }

    func search(query: String, page: Int) async throws -> SearchResult {
        try await searchHandler(query, page)
    }
}

final class MockChannelRepository: ChannelRepositoryProtocol {
    var getChannelHandler: (String) async throws -> Channel = { _ in TestData.channel() }
    var setSubscribedHandler: (String, Bool) async throws -> Void = { _, _ in }

    func getChannel(id: String) async throws -> Channel {
        try await getChannelHandler(id)
    }

    func setSubscribed(channelId: String, subscribed: Bool) async throws {
        try await setSubscribedHandler(channelId, subscribed)
    }
}

final class MockDownloadRepository: DownloadRepositoryProtocol {
    var getDownloadsHandler: (Int, String) async throws -> DownloadListResult = { _, _ in
        DownloadListResult(items: [], currentPage: 1, lastPage: 1)
    }
    var updateStatusHandler: (String, String) async throws -> Void = { _, _ in }
    var deleteDownloadHandler: (String) async throws -> Void = { _ in }
    var addToQueueHandler: (String) async throws -> Void = { _ in }
    var startDownloadHandler: () async throws -> Void = {}
    var getNotificationsHandler: () async throws -> [TaskNotification] = { [] }
    var killTaskHandler: (String) async throws -> Void = { _ in }
    var rescanSubscriptionsHandler: () async throws -> Void = {}

    func getDownloads(page: Int, filter: String) async throws -> DownloadListResult {
        try await getDownloadsHandler(page, filter)
    }

    func updateStatus(videoId: String, status: String) async throws {
        try await updateStatusHandler(videoId, status)
    }

    func deleteDownload(videoId: String) async throws {
        try await deleteDownloadHandler(videoId)
    }

    func addToQueue(videoId: String) async throws {
        try await addToQueueHandler(videoId)
    }

    func startDownload() async throws {
        try await startDownloadHandler()
    }

    func getNotifications() async throws -> [TaskNotification] {
        try await getNotificationsHandler()
    }

    func killTask(id: String) async throws {
        try await killTaskHandler(id)
    }

    func rescanSubscriptions() async throws {
        try await rescanSubscriptionsHandler()
    }
}

final class MockPlaylistRepository: PlaylistRepositoryProtocol {
    var getPlaylistsHandler: (Int, String?) async throws -> PlaylistListResult = { _, _ in
        PlaylistListResult(playlists: [], currentPage: 1, lastPage: 1)
    }
    var getPlaylistHandler: (String) async throws -> Playlist = { _ in TestData.playlist() }
    var getPlaylistVideosHandler: (String, Int) async throws -> VideoListResult = { _, _ in
        VideoListResult(videos: [], currentPage: 1, lastPage: 1, totalHits: 0)
    }
    var createCustomPlaylistHandler: (String) async throws -> Playlist = { name in TestData.playlist(playlistName: name, playlistType: .custom) }
    var updateSubscriptionHandler: (String, Bool) async throws -> Void = { _, _ in }
    var addVideoToPlaylistHandler: (String, String) async throws -> Void = { _, _ in }
    var removeVideoFromPlaylistHandler: (String, String) async throws -> Void = { _, _ in }
    var deletePlaylistHandler: (String, Bool) async throws -> Void = { _, _ in }

    func getPlaylists(page: Int, type: String?) async throws -> PlaylistListResult {
        try await getPlaylistsHandler(page, type)
    }

    func getPlaylist(id: String) async throws -> Playlist {
        try await getPlaylistHandler(id)
    }

    func getPlaylistVideos(playlistId: String, page: Int) async throws -> VideoListResult {
        try await getPlaylistVideosHandler(playlistId, page)
    }

    func createCustomPlaylist(name: String) async throws -> Playlist {
        try await createCustomPlaylistHandler(name)
    }

    func updateSubscription(playlistId: String, subscribed: Bool) async throws {
        try await updateSubscriptionHandler(playlistId, subscribed)
    }

    func addVideoToPlaylist(playlistId: String, videoId: String) async throws {
        try await addVideoToPlaylistHandler(playlistId, videoId)
    }

    func removeVideoFromPlaylist(playlistId: String, videoId: String) async throws {
        try await removeVideoFromPlaylistHandler(playlistId, videoId)
    }

    func deletePlaylist(id: String, deleteVideos: Bool) async throws {
        try await deletePlaylistHandler(id, deleteVideos)
    }
}

// MARK: - Mock Router Factory

/// Builds a fresh `(KeychainService, AuthState, AppRouter)` triple for tests.
///
/// Many tests need only the `AppRouter` but must construct the keychain +
/// auth-state stack first. This helper hides the boilerplate while keeping
/// each call independent (no shared static state across tests).
@MainActor
func makeMockRouter() -> (keychain: KeychainService, authState: AuthState, router: AppRouter) {
    let keychain = KeychainService()
    let authState = AuthState(keychainService: keychain)
    let router = AppRouter(authState: authState)
    return (keychain, authState, router)
}

// MARK: - Test Data Factory

enum TestData {
    static func video(
        youtubeId: String = "test-video-id",
        title: String = "Test Video",
        position: Double = 0,
        duration: Int = 600,
        watched: Bool = false,
        streams: [StreamInfo] = [],
        sponsorblock: [SponsorBlockSegment] = [],
        playlists: [String] = []
    ) -> Video {
        Video(
            youtubeId: youtubeId,
            title: title,
            description: "Test description",
            published: "2024-01-01",
            publishedShort: "Jan 1",
            downloaded: "2024-01-02",
            downloadedShort: "1/2/24",
            channelName: "Test Channel",
            channelId: "test-channel-id",
            channelThumbUrl: "https://example.com/thumb.jpg",
            thumbUrl: "https://example.com/video-thumb.jpg",
            mediaUrl: "https://example.com/video.mp4",
            duration: duration,
            durationStr: "10:00",
            watched: watched,
            progress: position > 0 ? position / Double(duration) : 0,
            position: position,
            viewCount: 1000,
            likeCount: 100,
            mediaSize: 50_000_000,
            vidType: "videos",
            category: ["Science"],
            tags: ["test"],
            streams: streams,
            sponsorblock: sponsorblock,
            playlists: playlists
        )
    }

    static func channel(
        channelId: String = "test-channel-id",
        channelName: String = "Test Channel"
    ) -> Channel {
        Channel(
            channelId: channelId,
            channelName: channelName,
            channelThumbUrl: "https://example.com/channel-thumb.jpg",
            channelBannerUrl: "https://example.com/channel-banner.jpg",
            channelDescription: "A test channel",
            channelSubscribed: true,
            channelSubs: 5000
        )
    }

    static func comment(
        id: String = "comment-1",
        author: String = "Test User",
        text: String = "Great video!",
        replies: [Comment] = []
    ) -> Comment {
        Comment(
            id: id,
            author: author,
            authorId: "author-1",
            authorThumbnailUrl: "https://example.com/author-thumb.jpg",
            isUploader: false,
            text: text,
            timeText: "1 day ago",
            likeCount: 5,
            isFavorited: false,
            parentId: "root",
            replies: replies
        )
    }

    static func downloadItem(
        youtubeId: String = "dl-video-id",
        title: String = "Download Video",
        status: String = "pending"
    ) -> DownloadItem {
        DownloadItem(
            youtubeId: youtubeId,
            title: title,
            channelName: "Test Channel",
            channelId: "test-channel-id",
            duration: "10:00",
            published: "2024-01-01",
            status: status,
            message: nil,
            thumbUrl: "https://example.com/dl-thumb.jpg",
            vidType: "videos",
            timestamp: 1704067200
        )
    }

    static func playlist(
        playlistId: String = "test-playlist-id",
        playlistName: String = "Test Playlist",
        playlistType: PlaylistType = .regular,
        playlistSubscribed: Bool = true,
        entries: [PlaylistEntry] = []
    ) -> Playlist {
        Playlist(
            playlistId: playlistId,
            playlistName: playlistName,
            playlistChannel: "Test Channel",
            playlistChannelId: "test-channel-id",
            playlistType: playlistType,
            playlistSubscribed: playlistSubscribed,
            playlistThumbnail: "https://example.com/playlist-thumb.jpg",
            playlistDescription: "A test playlist",
            playlistEntries: entries
        )
    }

    static func playlistListResult(
        count: Int = 3,
        currentPage: Int = 1,
        lastPage: Int = 1
    ) -> PlaylistListResult {
        let playlists = (0..<count).map { i in
            playlist(playlistId: "playlist-\(i)", playlistName: "Playlist \(i)")
        }
        return PlaylistListResult(playlists: playlists, currentPage: currentPage, lastPage: lastPage)
    }

    static func videoListResult(
        count: Int = 3,
        startIndex: Int = 0,
        currentPage: Int = 1,
        lastPage: Int = 1
    ) -> VideoListResult {
        let videos = (startIndex..<startIndex + count).map { i in
            video(youtubeId: "video-\(i)", title: "Video \(i)")
        }
        return VideoListResult(videos: videos, currentPage: currentPage, lastPage: lastPage, totalHits: count)
    }

    static func downloadListResult(
        count: Int = 3,
        currentPage: Int = 1,
        lastPage: Int = 1
    ) -> DownloadListResult {
        let items = (0..<count).map { i in
            downloadItem(youtubeId: "dl-\(i)", title: "Download \(i)")
        }
        return DownloadListResult(items: items, currentPage: currentPage, lastPage: lastPage)
    }
}
