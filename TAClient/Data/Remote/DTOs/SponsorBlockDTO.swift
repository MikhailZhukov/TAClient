import Foundation

struct SponsorBlockDTO: Decodable {
    let isEnabled: Bool?
    let lastRefresh: Int?
    let hasUnlocked: Bool?
    let segments: [SponsorBlockSegmentDTO]?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case lastRefresh = "last_refresh"
        case hasUnlocked = "has_unlocked"
        case segments
    }
}

struct SponsorBlockSegmentDTO: Decodable {
    let actionType: String?
    let videoDuration: Double?
    let segment: [Double]?
    let votes: Int?
    let category: String?
    let UUID: String?
    let locked: Int?
}
