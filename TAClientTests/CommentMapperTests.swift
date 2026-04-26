import Testing
@testable import TAClient

struct CommentMapperTests {

    private let serverURL = "https://ta.example.com"

    @Test func minimalValidDTO_returnsComment() {
        let dto = CommentDTO(
            commentAuthor: "Alice", commentAuthorId: nil,
            commentAuthorIsUploader: nil, commentAuthorThumbnail: nil,
            commentId: "c1", commentIsFavorited: nil, commentLikecount: nil,
            commentParent: nil, commentText: "Great video!",
            commentTimeText: nil, commentTimestamp: nil, commentReplies: nil
        )
        let comment = CommentMapper.map(dto, serverURL: serverURL)
        #expect(comment != nil)
        #expect(comment?.id == "c1")
        #expect(comment?.author == "Alice")
        #expect(comment?.text == "Great video!")
        #expect(comment?.authorId == "")
        #expect(comment?.likeCount == 0)
        #expect(comment?.parentId == "root")
        #expect(comment?.replies.isEmpty == true)
    }

    @Test func missingCommentId_returnsNil() {
        let dto = CommentDTO(
            commentAuthor: "Alice", commentAuthorId: nil,
            commentAuthorIsUploader: nil, commentAuthorThumbnail: nil,
            commentId: nil, commentIsFavorited: nil, commentLikecount: nil,
            commentParent: nil, commentText: "Hello",
            commentTimeText: nil, commentTimestamp: nil, commentReplies: nil
        )
        #expect(CommentMapper.map(dto, serverURL: serverURL) == nil)
    }

    @Test func missingCommentAuthor_returnsNil() {
        let dto = CommentDTO(
            commentAuthor: nil, commentAuthorId: nil,
            commentAuthorIsUploader: nil, commentAuthorThumbnail: nil,
            commentId: "c1", commentIsFavorited: nil, commentLikecount: nil,
            commentParent: nil, commentText: "Hello",
            commentTimeText: nil, commentTimestamp: nil, commentReplies: nil
        )
        #expect(CommentMapper.map(dto, serverURL: serverURL) == nil)
    }

    @Test func missingCommentText_returnsNil() {
        let dto = CommentDTO(
            commentAuthor: "Alice", commentAuthorId: nil,
            commentAuthorIsUploader: nil, commentAuthorThumbnail: nil,
            commentId: "c1", commentIsFavorited: nil, commentLikecount: nil,
            commentParent: nil, commentText: nil,
            commentTimeText: nil, commentTimestamp: nil, commentReplies: nil
        )
        #expect(CommentMapper.map(dto, serverURL: serverURL) == nil)
    }

    @Test func fullDTO_allFieldsMapped() {
        let dto = CommentDTO(
            commentAuthor: "Bob", commentAuthorId: "UCbob",
            commentAuthorIsUploader: true, commentAuthorThumbnail: "/thumb/bob.jpg",
            commentId: "c99", commentIsFavorited: true, commentLikecount: 42,
            commentParent: "c1", commentText: "Thanks!",
            commentTimeText: "2 days ago", commentTimestamp: 1705276800,
            commentReplies: nil
        )
        let comment = CommentMapper.map(dto, serverURL: serverURL)!
        #expect(comment.id == "c99")
        #expect(comment.author == "Bob")
        #expect(comment.authorId == "UCbob")
        #expect(comment.authorThumbnailUrl == "\(serverURL)/thumb/bob.jpg")
        #expect(comment.isUploader == true)
        #expect(comment.text == "Thanks!")
        #expect(comment.timeText == "2 days ago")
        #expect(comment.likeCount == 42)
        #expect(comment.isFavorited == true)
        #expect(comment.parentId == "c1")
    }

    @Test func nestedReplies_recursivelyMapped() {
        let reply = CommentDTO(
            commentAuthor: "Charlie", commentAuthorId: nil,
            commentAuthorIsUploader: nil, commentAuthorThumbnail: nil,
            commentId: "c2", commentIsFavorited: nil, commentLikecount: nil,
            commentParent: "c1", commentText: "Reply here",
            commentTimeText: nil, commentTimestamp: nil, commentReplies: nil
        )
        let dto = CommentDTO(
            commentAuthor: "Alice", commentAuthorId: nil,
            commentAuthorIsUploader: nil, commentAuthorThumbnail: nil,
            commentId: "c1", commentIsFavorited: nil, commentLikecount: nil,
            commentParent: nil, commentText: "Root comment",
            commentTimeText: nil, commentTimestamp: nil, commentReplies: [reply]
        )
        let comment = CommentMapper.map(dto, serverURL: serverURL)!
        #expect(comment.replies.count == 1)
        #expect(comment.replies[0].id == "c2")
        #expect(comment.replies[0].text == "Reply here")
    }

    @Test func replyWithMissingRequiredField_filteredOut() {
        let validReply = CommentDTO(
            commentAuthor: "Charlie", commentAuthorId: nil,
            commentAuthorIsUploader: nil, commentAuthorThumbnail: nil,
            commentId: "c2", commentIsFavorited: nil, commentLikecount: nil,
            commentParent: "c1", commentText: "Valid reply",
            commentTimeText: nil, commentTimestamp: nil, commentReplies: nil
        )
        let invalidReply = CommentDTO(
            commentAuthor: nil, commentAuthorId: nil,
            commentAuthorIsUploader: nil, commentAuthorThumbnail: nil,
            commentId: "c3", commentIsFavorited: nil, commentLikecount: nil,
            commentParent: "c1", commentText: "Invalid — no author",
            commentTimeText: nil, commentTimestamp: nil, commentReplies: nil
        )
        let dto = CommentDTO(
            commentAuthor: "Alice", commentAuthorId: nil,
            commentAuthorIsUploader: nil, commentAuthorThumbnail: nil,
            commentId: "c1", commentIsFavorited: nil, commentLikecount: nil,
            commentParent: nil, commentText: "Root",
            commentTimeText: nil, commentTimestamp: nil,
            commentReplies: [validReply, invalidReply]
        )
        let comment = CommentMapper.map(dto, serverURL: serverURL)!
        #expect(comment.replies.count == 1)
        #expect(comment.replies[0].id == "c2")
    }
}
