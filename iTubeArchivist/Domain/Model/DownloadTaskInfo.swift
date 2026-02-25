import Foundation

struct DownloadTaskInfo {
    let id: String
    let title: String
    let messages: [String]
    let progress: Double
    let isError: Bool
    let canStop: Bool
}
