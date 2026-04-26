import Foundation

struct Playlist: Identifiable, Hashable {
    var id: String { playlistId }

    let playlistId: String
    let playlistName: String
    let playlistChannel: String
    let playlistChannelId: String
    let playlistType: PlaylistType
    var playlistSubscribed: Bool
    let playlistThumbnail: String
    let playlistDescription: String?
    let playlistEntries: [PlaylistEntry]
}

struct PlaylistEntry: Identifiable, Hashable {
    var id: String { youtubeId }

    let youtubeId: String
    let title: String
    let uploader: String?
    let idx: Int
    let downloaded: Bool
}

enum PlaylistType: String {
    case regular
    case custom
}

struct PlaylistListResult {
    let playlists: [Playlist]
    let currentPage: Int
    let lastPage: Int
}
