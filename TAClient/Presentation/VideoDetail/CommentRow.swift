import SwiftUI

struct CommentRow: View {
    let comment: Comment
    let depth: Int
    @State private var showReplies = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                AuthenticatedAsyncImage(
                    url: comment.authorThumbnailUrl,
                    placeholderColor: Color(.tertiarySystemBackground)
                )
                .frame(width: 32, height: 32)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(comment.author)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(comment.isUploader ? Color.accentColor : .primary)
                        Text(comment.timeText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Text(comment.text)
                        .font(.caption)

                    if comment.likeCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "hand.thumbsup")
                                .font(.caption2)
                            Text("\(comment.likeCount)")
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }

            // Replies toggle
            if !comment.replies.isEmpty {
                Button {
                    withAnimation {
                        showReplies.toggle()
                    }
                } label: {
                    Text(showReplies
                         ? String(localized: "video_detail_hide_replies")
                         : String(localized: "video_detail_show_replies \(comment.replies.count)"))
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }

                if showReplies {
                    ForEach(comment.replies) { reply in
                        CommentRow(comment: reply, depth: depth + 1)
                            .padding(.leading, 24)
                    }
                }
            }
        }
    }
}
