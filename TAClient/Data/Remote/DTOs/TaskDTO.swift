import Foundation

struct NotificationDTO: Decodable {
    let id: String?
    let title: String?
    let group: String?
    let level: String?
    let messages: [String]?
    let progress: Double?
    let apiStop: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, group, level, messages, progress
        case apiStop = "api_stop"
    }
}

struct TaskCommandDTO: Encodable {
    let command: String
}
