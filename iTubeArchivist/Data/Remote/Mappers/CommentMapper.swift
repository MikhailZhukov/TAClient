import Foundation

enum CommentMapper {
    static func map(_ dto: CommentDTO, serverURL: String) -> Comment? {
        guard let id = dto.commentId,
              let author = dto.commentAuthor,
              let text = dto.commentText else {
            return nil
        }

        return Comment(
            id: id,
            author: author,
            authorId: dto.commentAuthorId ?? "",
            authorThumbnailUrl: VideoMapper.resolveURL(dto.commentAuthorThumbnail, baseURL: serverURL) ?? "",
            isUploader: dto.commentAuthorIsUploader ?? false,
            text: text,
            timeText: dto.commentTimeText ?? "",
            likeCount: dto.commentLikecount ?? 0,
            isFavorited: dto.commentIsFavorited ?? false,
            parentId: dto.commentParent ?? "root",
            replies: dto.commentReplies?.compactMap { map($0, serverURL: serverURL) } ?? []
        )
    }
}
