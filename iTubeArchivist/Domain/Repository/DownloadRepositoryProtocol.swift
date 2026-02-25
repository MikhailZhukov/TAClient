import Foundation

protocol DownloadRepositoryProtocol {
    func getDownloads(page: Int, filter: String) async throws -> DownloadListResult
    func updateStatus(videoId: String, status: String) async throws
    func deleteDownload(videoId: String) async throws
    func addToQueue(videoId: String) async throws
    func startDownload() async throws
    func getDownloadNotifications() async throws -> [DownloadTaskInfo]
    func killTask(id: String) async throws
}
