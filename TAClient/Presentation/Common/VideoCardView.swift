import SwiftUI

struct VideoCardView: View {
    let video: Video
    var onChannelTap: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Thumbnail with overlays
            ZStack(alignment: .bottom) {
                AuthenticatedAsyncImage(url: video.thumbUrl)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipped()

                // Overlay badges
                HStack(alignment: .bottom) {
                    QualityBadge(streams: video.streams)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        // Duration badge
                        Text(video.durationStr)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.7))
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                        // Date badge
                        Text(video.publishedShort)
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.7))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                .padding(8)

                // Progress bar
                if video.progress > 0 && !video.watched {
                    GeometryReader { geo in
                        VStack {
                            Spacer()
                            Rectangle()
                                .fill(Color.red)
                                .frame(width: geo.size.width * video.progress / 100, height: 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Title (fixed height for uniform grid rows)
            Text(video.title)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: UIFont.preferredFont(forTextStyle: .subheadline).lineHeight * 2 + 4)

            // Channel info
            Button {
                if !video.channelId.isEmpty {
                    onChannelTap?(video.channelId)
                }
            } label: {
                HStack(spacing: 8) {
                    AuthenticatedAsyncImage(
                        url: video.channelThumbUrl,
                        placeholderColor: Color(.tertiarySystemBackground)
                    )
                    .frame(width: 20, height: 20)
                    .clipShape(Circle())

                    Text(video.channelName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityLabel(video.channelName)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(video.title), \(video.channelName), \(video.durationStr)")
    }
}
