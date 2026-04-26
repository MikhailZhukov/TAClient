import Foundation

struct TaskNotification {
    let id: String
    let title: String
    let group: String
    let messages: [String]
    let progress: Double
    let isError: Bool
    let canStop: Bool
}
