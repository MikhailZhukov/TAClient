import Foundation

struct CommentListDTO: Decodable {
    // Comments endpoint returns an array directly or wrapped
    // We handle both cases via custom decoding in repository
}

struct CommentDTO: Decodable {
    let commentAuthor: String?
    let commentAuthorId: String?
    let commentAuthorIsUploader: Bool?
    let commentAuthorThumbnail: String?
    let commentId: String?
    let commentIsFavorited: Bool?
    let commentLikecount: Int?
    let commentParent: String?
    let commentText: String?
    let commentTimeText: String?
    let commentTimestamp: Int?
    let commentReplies: [CommentDTO]?

    enum CodingKeys: String, CodingKey {
        case commentAuthor = "comment_author"
        case commentAuthorId = "comment_author_id"
        case commentAuthorIsUploader = "comment_author_is_uploader"
        case commentAuthorThumbnail = "comment_author_thumbnail"
        case commentId = "comment_id"
        case commentIsFavorited = "comment_is_favorited"
        case commentLikecount = "comment_likecount"
        case commentParent = "comment_parent"
        case commentText = "comment_text"
        case commentTimeText = "comment_time_text"
        case commentTimestamp = "comment_timestamp"
        case commentReplies = "comment_replies"
    }
}
