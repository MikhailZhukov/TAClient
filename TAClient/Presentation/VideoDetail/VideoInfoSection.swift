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
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())

                    Text(video.channelName)
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                }
            }

            // Stats/dates + Media info
            ViewThatFits(in: .horizontal) {
                datesAndMedia(short: false)
                datesAndMedia(short: true)
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func datesAndMedia(short: Bool) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 16) {
                    Label("\(video.viewCount)", systemImage: "eye")
                    Label("\(video.likeCount)", systemImage: "hand.thumbsup")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(String(localized: "video_detail_published \(short ? video.publishedShort : video.published)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(String(localized: "video_detail_downloaded \(short ? video.downloadedShort : video.downloaded)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !video.streams.isEmpty {
                Spacer()
                mediaInfoSection
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var mediaInfoSection: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(video.streams, id: \.self) { stream in
                HStack(spacing: 4) {
                    Text(stream.type.capitalized)
                        .fontWeight(.medium)
                    Text(stream.codec)
                    if let w = stream.width, let h = stream.height {
                        Text("\(w)x\(h)")
                    }
                    if stream.bitrate > 0 {
                        Text("\(stream.bitrate / 1000)kbps")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            }
            Text(String(localized: "video_detail_file_size \(FormattedFileSize.format(video.mediaSize))"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }
}
