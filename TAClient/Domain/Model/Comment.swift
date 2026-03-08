import Foundation

struct Comment: Identifiable, Hashable {
    let id: String
    let author: String
    let authorId: String
    let authorThumbnailUrl: String
    let isUploader: Bool
    let text: String
    let timeText: String
    let likeCount: Int
    let isFavorited: Bool
    let parentId: String
    let replies: [Comment]
}
