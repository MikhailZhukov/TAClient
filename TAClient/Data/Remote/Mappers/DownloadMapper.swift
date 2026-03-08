import Foundation

enum DownloadMapper {
    static func map(_ dto: DownloadItemDTO, serverURL: String) -> DownloadItem? {
        guard let youtubeId = dto.youtubeId,
              let title = dto.title else { return nil }

        return DownloadItem(
            youtubeId: youtubeId,
            title: title,
            channelName: dto.channelName ?? "",
            channelId: dto.channelId ?? "",
            duration: dto.duration ?? "",
            published: DateFormatting.formatISO(dto.published, style: .short),
            status: dto.status ?? "pending",
            message: dto.message,
            thumbUrl: resolveURL(dto.vidThumbUrl, baseURL: serverURL),
            vidType: dto.vidType ?? "videos",
            timestamp: dto.timestamp ?? 0
        )
    }

    static func resolveURL(_ path: String?, baseURL: String) -> String? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http") { return path }
        return baseURL + path
    }
}
