import Foundation

protocol PlaylistRepositoryProtocol {
    func getPlaylists(page: Int, type: String?) async throws -> PlaylistListResult
    func getPlaylist(id: String) async throws -> Playlist
    func getPlaylistVideos(playlistId: String, page: Int) async throws -> VideoListResult
    func createCustomPlaylist(name: String) async throws -> Playlist
    func updateSubscription(playlistId: String, subscribed: Bool) async throws
    func addVideoToPlaylist(playlistId: String, videoId: String) async throws
    func removeVideoFromPlaylist(playlistId: String, videoId: String) async throws
    func deletePlaylist(id: String, deleteVideos: Bool) async throws
}
