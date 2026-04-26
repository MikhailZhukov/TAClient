import Testing
@testable import TAClient

struct VideoMapperTests {

    private let serverURL = "https://ta.example.com"

    // MARK: - map

    @Test func minimalValidDTO_returnsVideo() {
        let dto = VideoDTO(
            youtubeId: "abc123", title: "Test Video", description: nil,
            published: nil, dateDownloaded: nil, active: nil, channel: nil,
            vidThumbUrl: nil, mediaUrl: nil, mediaSize: nil, player: nil,
            stats: nil, vidType: nil, category: nil, tags: nil, streams: nil, sponsorblock: nil, playlist: nil
        )
        let video = VideoMapper.map(dto, serverURL: serverURL)
        #expect(video != nil)
        #expect(video?.youtubeId == "abc123")
        #expect(video?.title == "Test Video")
        #expect(video?.channelName == "")
        #expect(video?.duration == 0)
        #expect(video?.streams.isEmpty == true)
    }

    @Test func missingYoutubeId_returnsNil() {
        let dto = VideoDTO(
            youtubeId: nil, title: "Test", description: nil,
            published: nil, dateDownloaded: nil, active: nil, channel: nil,
            vidThumbUrl: nil, mediaUrl: nil, mediaSize: nil, player: nil,
            stats: nil, vidType: nil, category: nil, tags: nil, streams: nil, sponsorblock: nil, playlist: nil
        )
        #expect(VideoMapper.map(dto, serverURL: serverURL) == nil)
    }

    @Test func missingTitle_returnsNil() {
        let dto = VideoDTO(
            youtubeId: "abc123", title: nil, description: nil,
            published: nil, dateDownloaded: nil, active: nil, channel: nil,
            vidThumbUrl: nil, mediaUrl: nil, mediaSize: nil, player: nil,
            stats: nil, vidType: nil, category: nil, tags: nil, streams: nil, sponsorblock: nil, playlist: nil
        )
        #expect(VideoMapper.map(dto, serverURL: serverURL) == nil)
    }

    @Test func fullDTO_allFieldsMapped() {
        let channel = ChannelInfoDTO(
            channelId: "ch1", channelName: "Channel",
            channelThumbUrl: "/thumb/ch.jpg", channelBannerUrl: nil,
            channelDescription: nil, channelSubscribed: nil, channelSubs: nil
        )
        let player = PlayerDTO(
            watched: true, duration: 300, durationStr: "5:00",
            progress: 0.5, position: 150.0
        )
        let stats = StatsDTO(
            viewCount: 1000, likeCount: 50,
            dislikeCount: 2, averageRating: 4.9
        )
        let stream = StreamDTO(
            type: "video", index: 0, codec: "h264",
            bitrate: 5000, width: 1920, height: 1080
        )
        let dto = VideoDTO(
            youtubeId: "xyz789", title: "Full Video", description: "A description",
            published: "2024-01-15", dateDownloaded: 1705276800, active: true,
            channel: channel, vidThumbUrl: "/thumb/vid.jpg", mediaUrl: "/media/vid.mp4",
            mediaSize: 100_000_000, player: player, stats: stats,
            vidType: "shorts", category: ["Music"], tags: ["tag1"], streams: [stream],
            sponsorblock: nil, playlist: nil
        )

        let video = VideoMapper.map(dto, serverURL: serverURL)!
        #expect(video.youtubeId == "xyz789")
        #expect(video.title == "Full Video")
        #expect(video.description == "A description")
        #expect(video.channelName == "Channel")
        #expect(video.channelId == "ch1")
        #expect(video.channelThumbUrl == "\(serverURL)/thumb/ch.jpg")
        #expect(video.thumbUrl == "\(serverURL)/thumb/vid.jpg")
        #expect(video.mediaUrl == "\(serverURL)/media/vid.mp4")
        #expect(video.duration == 300)
        #expect(video.durationStr == "5:00")
        #expect(video.watched == true)
        #expect(video.progress == 0.5)
        #expect(video.position == 150.0)
        #expect(video.viewCount == 1000)
        #expect(video.likeCount == 50)
        #expect(video.mediaSize == 100_000_000)
        #expect(video.vidType == "shorts")
        #expect(video.category == ["Music"])
        #expect(video.tags == ["tag1"])
        #expect(video.streams.count == 1)
        #expect(video.streams[0].codec == "h264")
    }

    @Test func relativeThumbUrl_prependsServerURL() {
        let dto = VideoDTO(
            youtubeId: "abc", title: "T", description: nil,
            published: nil, dateDownloaded: nil, active: nil, channel: nil,
            vidThumbUrl: "/cache/thumb.jpg", mediaUrl: nil, mediaSize: nil,
            player: nil, stats: nil, vidType: nil, category: nil, tags: nil, streams: nil, sponsorblock: nil, playlist: nil
        )
        let video = VideoMapper.map(dto, serverURL: serverURL)
        #expect(video?.thumbUrl == "\(serverURL)/cache/thumb.jpg")
    }

    @Test func absoluteThumbUrl_keptAsIs() {
        let dto = VideoDTO(
            youtubeId: "abc", title: "T", description: nil,
            published: nil, dateDownloaded: nil, active: nil, channel: nil,
            vidThumbUrl: "https://cdn.example.com/thumb.jpg", mediaUrl: nil,
            mediaSize: nil, player: nil, stats: nil, vidType: nil,
            category: nil, tags: nil, streams: nil, sponsorblock: nil, playlist: nil
        )
        let video = VideoMapper.map(dto, serverURL: serverURL)
        #expect(video?.thumbUrl == "https://cdn.example.com/thumb.jpg")
    }

    @Test func nilThumbUrl_defaultsToEmpty() {
        let dto = VideoDTO(
            youtubeId: "abc", title: "T", description: nil,
            published: nil, dateDownloaded: nil, active: nil, channel: nil,
            vidThumbUrl: nil, mediaUrl: nil, mediaSize: nil, player: nil,
            stats: nil, vidType: nil, category: nil, tags: nil, streams: nil, sponsorblock: nil, playlist: nil
        )
        let video = VideoMapper.map(dto, serverURL: serverURL)
        #expect(video?.thumbUrl == "")
    }

    @Test func streamWithNilCodec_filteredOut() {
        let streams = [
            StreamDTO(type: "video", index: 0, codec: "h264", bitrate: 5000, width: 1920, height: 1080),
            StreamDTO(type: "audio", index: 1, codec: nil, bitrate: 128, width: nil, height: nil)
        ]
        let dto = VideoDTO(
            youtubeId: "abc", title: "T", description: nil,
            published: nil, dateDownloaded: nil, active: nil, channel: nil,
            vidThumbUrl: nil, mediaUrl: nil, mediaSize: nil, player: nil,
            stats: nil, vidType: nil, category: nil, tags: nil, streams: streams,
            sponsorblock: nil, playlist: nil
        )
        let video = VideoMapper.map(dto, serverURL: serverURL)
        #expect(video?.streams.count == 1)
        #expect(video?.streams[0].codec == "h264")
    }

    // MARK: - resolveURL

    @Test func resolveURL_nil_returnsNil() {
        #expect(VideoMapper.resolveURL(nil, baseURL: serverURL) == nil)
    }

    @Test func resolveURL_empty_returnsNil() {
        #expect(VideoMapper.resolveURL("", baseURL: serverURL) == nil)
    }

    @Test func resolveURL_relativePath_prependsBase() {
        #expect(VideoMapper.resolveURL("/api/thumb.jpg", baseURL: serverURL) == "\(serverURL)/api/thumb.jpg")
    }

    @Test func resolveURL_absoluteURL_returnedAsIs() {
        let absolute = "https://other.com/image.jpg"
        #expect(VideoMapper.resolveURL(absolute, baseURL: serverURL) == absolute)
    }
}
