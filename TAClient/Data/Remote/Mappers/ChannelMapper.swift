import Foundation

enum ChannelMapper {
    static func map(_ dto: ChannelDTO, serverURL: String) -> Channel? {
        guard let channelId = dto.channelId,
              let channelName = dto.channelName else {
            return nil
        }

        return Channel(
            channelId: channelId,
            channelName: channelName,
            channelThumbUrl: VideoMapper.resolveURL(dto.channelThumbUrl, baseURL: serverURL),
            channelBannerUrl: VideoMapper.resolveURL(dto.channelBannerUrl, baseURL: serverURL),
            channelDescription: dto.channelDescription,
            channelSubscribed: dto.channelSubscribed ?? false,
            channelSubs: dto.channelSubs ?? 0
        )
    }

    static func mapFromVideoDTO(_ dto: ChannelInfoDTO, serverURL: String) -> Channel? {
        guard let channelId = dto.channelId,
              let channelName = dto.channelName else {
            return nil
        }

        return Channel(
            channelId: channelId,
            channelName: channelName,
            channelThumbUrl: VideoMapper.resolveURL(dto.channelThumbUrl, baseURL: serverURL),
            channelBannerUrl: VideoMapper.resolveURL(dto.channelBannerUrl, baseURL: serverURL),
            channelDescription: dto.channelDescription,
            channelSubscribed: dto.channelSubscribed ?? false,
            channelSubs: dto.channelSubs ?? 0
        )
    }
}
