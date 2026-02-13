import SwiftUI

struct VideoInfoSection: View {
    let video: Video
    var onChannelTap: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title
            Text(video.title)
                .font(.headline)

            // Channel
            HStack(spacing: 8) {
                AuthenticatedAsyncImage(
                    url: video.channelThumbUrl,
                    placeholderColor: Color(hex: 0x3A3A3A)
                )
                .frame(width: 32, height: 32)
                .clipShape(Circle())

                Text(video.channelName)
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
            }
            .onTapGesture {
                if !video.channelId.isEmpty {
                    onChannelTap?(video.channelId)
                }
            }

            // Stats row
            HStack(spacing: 16) {
                Label("\(video.viewCount)", systemImage: "eye")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label("\(video.likeCount)", systemImage: "hand.thumbsup")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Dates
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "video_detail_published \(video.published)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(String(localized: "video_detail_downloaded \(video.downloaded)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Media info
            if !video.streams.isEmpty {
                Divider()
                mediaInfoSection
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var mediaInfoSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(video.streams, id: \.self) { stream in
                HStack {
                    Text(stream.type.capitalized)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    Text(stream.codec)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let w = stream.width, let h = stream.height {
                        Text("\(w)x\(h)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if stream.bitrate > 0 {
                        Text("\(stream.bitrate / 1000)kbps")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text(String(localized: "video_detail_file_size \(FormattedFileSize.format(video.mediaSize))"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
