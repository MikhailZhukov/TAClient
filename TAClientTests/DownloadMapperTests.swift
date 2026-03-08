import Testing
@testable import TAClient

struct DownloadMapperTests {

    private let serverURL = "https://ta.example.com"

    @Test func minimalValidDTO_returnsDownloadItem() {
        let dto = DownloadItemDTO(
            youtubeId: "dl1", title: "Download Me",
            channelName: nil, channelId: nil, duration: nil,
            published: nil, status: nil, message: nil,
            vidThumbUrl: nil, vidType: nil, timestamp: nil
        )
        let item = DownloadMapper.map(dto, serverURL: serverURL)
        #expect(item != nil)
        #expect(item?.youtubeId == "dl1")
        #expect(item?.title == "Download Me")
        #expect(item?.channelName == "")
        #expect(item?.status == "pending")
        #expect(item?.message == nil)
        #expect(item?.thumbUrl == nil)
    }

    @Test func missingYoutubeId_returnsNil() {
        let dto = DownloadItemDTO(
            youtubeId: nil, title: "Title",
            channelName: nil, channelId: nil, duration: nil,
            published: nil, status: nil, message: nil,
            vidThumbUrl: nil, vidType: nil, timestamp: nil
        )
        #expect(DownloadMapper.map(dto, serverURL: serverURL) == nil)
    }

    @Test func missingTitle_returnsNil() {
        let dto = DownloadItemDTO(
            youtubeId: "dl1", title: nil,
            channelName: nil, channelId: nil, duration: nil,
            published: nil, status: nil, message: nil,
            vidThumbUrl: nil, vidType: nil, timestamp: nil
        )
        #expect(DownloadMapper.map(dto, serverURL: serverURL) == nil)
    }

    @Test func fullDTO_allFieldsMapped() {
        let dto = DownloadItemDTO(
            youtubeId: "dl99", title: "Full Download",
            channelName: "Channel", channelId: "UCch",
            duration: "10:30", published: "2024-06-01",
            status: "downloading", message: "50% done",
            vidThumbUrl: "/thumb/dl.jpg", vidType: "shorts", timestamp: 1717200000
        )
        let item = DownloadMapper.map(dto, serverURL: serverURL)!
        #expect(item.youtubeId == "dl99")
        #expect(item.title == "Full Download")
        #expect(item.channelName == "Channel")
        #expect(item.channelId == "UCch")
        #expect(item.duration == "10:30")
        #expect(item.status == "downloading")
        #expect(item.message == "50% done")
        #expect(item.thumbUrl == "\(serverURL)/thumb/dl.jpg")
        #expect(item.vidType == "shorts")
        #expect(item.timestamp == 1717200000)
    }

    @Test func relativeThumbUrl_prependsServerURL() {
        let dto = DownloadItemDTO(
            youtubeId: "dl1", title: "T",
            channelName: nil, channelId: nil, duration: nil,
            published: nil, status: nil, message: nil,
            vidThumbUrl: "/cache/thumb.jpg", vidType: nil, timestamp: nil
        )
        let item = DownloadMapper.map(dto, serverURL: serverURL)
        #expect(item?.thumbUrl == "\(serverURL)/cache/thumb.jpg")
    }

    @Test func absoluteThumbUrl_keptAsIs() {
        let dto = DownloadItemDTO(
            youtubeId: "dl1", title: "T",
            channelName: nil, channelId: nil, duration: nil,
            published: nil, status: nil, message: nil,
            vidThumbUrl: "https://cdn.example.com/thumb.jpg", vidType: nil, timestamp: nil
        )
        let item = DownloadMapper.map(dto, serverURL: serverURL)
        #expect(item?.thumbUrl == "https://cdn.example.com/thumb.jpg")
    }
}
