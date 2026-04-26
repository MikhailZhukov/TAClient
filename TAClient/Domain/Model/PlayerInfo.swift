import Foundation

struct PlayerInfo: Hashable {
    let watched: Bool
    let duration: Int
    let durationStr: String
    let progress: Double
    let position: Double
}
