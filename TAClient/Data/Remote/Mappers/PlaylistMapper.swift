import Foundation

enum PlaylistMapper {
    static func map(_ dto: PlaylistDTO, serverURL: String) -> Playlist? {
        guard let playlistId = dto.playlistId,
              let playlistName = dto.playlistName else {
            return nil
        }

        return Playlist(
            playlistId: playlistId,
            playlistName: playlistName,
            playlistChannel: dto.playlistChannel ?? "",
            playlistChannelId: dto.playlistChannelId ?? "",
            playlistType: PlaylistType(rawValue: dto.playlistType ?? "regular") ?? .regular,
            playlistSubscribed: dto.playlistSubscribed ?? false,
            playlistThumbnail: resolveURL(dto.playlistThumbnail, baseURL: serverURL) ?? "",
            playlistDescription: dto.playlistDescription,
            playlistEntries: dto.playlistEntries?.compactMap { mapEntry($0) } ?? []
        )
    }

    static func mapEntry(_ dto: PlaylistEntryDTO) -> PlaylistEntry? {
        guard let youtubeId = dto.youtubeId,
              let title = dto.title else { return nil }
        return PlaylistEntry(
            youtubeId: youtubeId,
            title: title,
            uploader: dto.uploader,
            idx: dto.idx ?? 0,
            downloaded: dto.downloaded ?? false
        )
    }

    static func resolveURL(_ path: String?, baseURL: String) -> String? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http") { return path }
        return baseURL + path
    }
}
