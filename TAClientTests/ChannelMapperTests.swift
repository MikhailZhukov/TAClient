import Testing
@testable import TAClient

struct ChannelMapperTests {

    private let serverURL = "https://ta.example.com"

    // MARK: - map (ChannelDTO)

    @Test func minimalValidDTO_returnsChannel() {
        let dto = ChannelDTO(
            channelId: "UCabc", channelName: "My Channel",
            channelThumbUrl: nil, channelBannerUrl: nil,
            channelDescription: nil, channelSubscribed: nil, channelSubs: nil
        )
        let channel = ChannelMapper.map(dto, serverURL: serverURL)
        #expect(channel != nil)
        #expect(channel?.channelId == "UCabc")
        #expect(channel?.channelName == "My Channel")
        #expect(channel?.channelSubscribed == false)
        #expect(channel?.channelSubs == 0)
    }

    @Test func missingChannelId_returnsNil() {
        let dto = ChannelDTO(
            channelId: nil, channelName: "Name",
            channelThumbUrl: nil, channelBannerUrl: nil,
            channelDescription: nil, channelSubscribed: nil, channelSubs: nil
        )
        #expect(ChannelMapper.map(dto, serverURL: serverURL) == nil)
    }

    @Test func missingChannelName_returnsNil() {
        let dto = ChannelDTO(
            channelId: "UCabc", channelName: nil,
            channelThumbUrl: nil, channelBannerUrl: nil,
            channelDescription: nil, channelSubscribed: nil, channelSubs: nil
        )
        #expect(ChannelMapper.map(dto, serverURL: serverURL) == nil)
    }

    @Test func fullDTO_allFieldsMapped() {
        let dto = ChannelDTO(
            channelId: "UCxyz", channelName: "Full Channel",
            channelThumbUrl: "/thumb/ch.jpg", channelBannerUrl: "/banner/ch.jpg",
            channelDescription: "A great channel", channelSubscribed: true, channelSubs: 50_000
        )
        let channel = ChannelMapper.map(dto, serverURL: serverURL)!
        #expect(channel.channelId == "UCxyz")
        #expect(channel.channelName == "Full Channel")
        #expect(channel.channelThumbUrl == "\(serverURL)/thumb/ch.jpg")
        #expect(channel.channelBannerUrl == "\(serverURL)/banner/ch.jpg")
        #expect(channel.channelDescription == "A great channel")
        #expect(channel.channelSubscribed == true)
        #expect(channel.channelSubs == 50_000)
    }

    // MARK: - mapFromVideoDTO (ChannelInfoDTO)

    @Test func mapFromVideoDTO_minimalValid() {
        let dto = ChannelInfoDTO(
            channelId: "UCabc", channelName: "From Video",
            channelThumbUrl: nil, channelBannerUrl: nil,
            channelDescription: nil, channelSubscribed: nil, channelSubs: nil
        )
        let channel = ChannelMapper.mapFromVideoDTO(dto, serverURL: serverURL)
        #expect(channel != nil)
        #expect(channel?.channelName == "From Video")
    }

    @Test func mapFromVideoDTO_missingId_returnsNil() {
        let dto = ChannelInfoDTO(
            channelId: nil, channelName: "Name",
            channelThumbUrl: nil, channelBannerUrl: nil,
            channelDescription: nil, channelSubscribed: nil, channelSubs: nil
        )
        #expect(ChannelMapper.mapFromVideoDTO(dto, serverURL: serverURL) == nil)
    }

    @Test func mapFromVideoDTO_urlResolution() {
        let dto = ChannelInfoDTO(
            channelId: "UCabc", channelName: "Name",
            channelThumbUrl: "/thumb.jpg", channelBannerUrl: "https://cdn.com/banner.jpg",
            channelDescription: nil, channelSubscribed: nil, channelSubs: nil
        )
        let channel = ChannelMapper.mapFromVideoDTO(dto, serverURL: serverURL)!
        #expect(channel.channelThumbUrl == "\(serverURL)/thumb.jpg")
        #expect(channel.channelBannerUrl == "https://cdn.com/banner.jpg")
    }
}
