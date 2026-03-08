import SwiftUI

struct CommentsSection: View {
    let comments: [Comment]
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
            } else if comments.isEmpty {
                Text(String(localized: "video_detail_no_comments"))
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .padding()
            } else {
                Text(commentsCountText)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .padding(.horizontal)

                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(comments) { comment in
                        CommentRow(comment: comment, depth: 0)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private var commentsCountText: String {
        let count = comments.count
        return String(localized: "video_detail_comments_count \(count)")
    }
}
