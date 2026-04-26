import Foundation

enum VideoMapper {
    static func map(_ dto: VideoDTO, serverURL: String) -> Video? {
        guard let youtubeId = dto.youtubeId,
              let title = dto.title else {
            return nil
        }

        let baseURL = serverURL

        return Video(
            youtubeId: youtubeId,
            title: title,
            description: dto.description,
            published: DateFormatting.formatISO(dto.published, style: .medium),
            publishedShort: DateFormatting.formatISO(dto.published, style: .short),
            downloaded: DateFormatting.formatUnixTimestamp(dto.dateDownloaded, style: .medium),
            downloadedShort: DateFormatting.formatUnixTimestamp(dto.dateDownloaded, style: .short),
            channelName: dto.channel?.channelName ?? "",
            channelId: dto.channel?.channelId ?? "",
            channelThumbUrl: resolveURL(dto.channel?.channelThumbUrl, baseURL: baseURL),
            thumbUrl: resolveURL(dto.vidThumbUrl, baseURL: baseURL) ?? "",
            mediaUrl: resolveURL(dto.mediaUrl, baseURL: baseURL) ?? "",
            duration: dto.player?.duration ?? 0,
            durationStr: dto.player?.durationStr ?? "0:00",
            watched: dto.player?.watched ?? false,
            progress: dto.player?.progress ?? 0.0,
            position: dto.player?.position ?? 0.0,
            viewCount: dto.stats?.viewCount ?? 0,
            likeCount: dto.stats?.likeCount ?? 0,
            mediaSize: dto.mediaSize ?? 0,
            vidType: dto.vidType ?? "videos",
            category: dto.category ?? [],
            tags: dto.tags ?? [],
            streams: dto.streams?.compactMap { streamDTO in
                guard let type = streamDTO.type,
                      let codec = streamDTO.codec else { return nil }
                return StreamInfo(
                    type: type,
                    codec: codec,
                    bitrate: streamDTO.bitrate ?? 0,
                    width: streamDTO.width,
                    height: streamDTO.height
                )
            } ?? [],
            sponsorblock: mapSponsorBlock(dto.sponsorblock),
            playlists: dto.playlist ?? []
        )
    }

    static func mapSponsorBlock(_ dto: SponsorBlockDTO?) -> [SponsorBlockSegment] {
        guard let dto, dto.isEnabled == true, let segments = dto.segments else { return [] }
        return segments.compactMap { segDTO in
            guard let categoryStr = segDTO.category,
                  let category = SponsorCategory(rawValue: categoryStr),
                  let times = segDTO.segment, times.count >= 2,
                  segDTO.actionType == "skip" else { return nil }
            let start = times[0]
            let end = times[1]
            guard start < end, start >= 0 else { return nil }
            return SponsorBlockSegment(category: category, startTime: start, endTime: end)
        }
    }

    static func resolveURL(_ path: String?, baseURL: String) -> String? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http") { return path }
        return baseURL + path
    }
}
