import Foundation

struct VideoListResult {
    let videos: [Video]
    let currentPage: Int
    let lastPage: Int
    let totalHits: Int
}

protocol VideoRepositoryProtocol {
    func getVideos(page: Int, sort: String, order: String, watch: String?, channel: String?, vidType: String?) async throws -> VideoListResult
    func getVideo(id: String) async throws -> Video
    func updateProgress(videoId: String, position: Double) async throws
    func deleteProgress(videoId: String) async throws
    func deleteVideo(id: String) async throws
    func ignoreVideo(id: String) async throws
    func getComments(videoId: String) async throws -> [Comment]
    func setWatched(videoId: String, isWatched: Bool) async throws
    func getSimilarVideos(videoId: String) async throws -> [Video]
}
