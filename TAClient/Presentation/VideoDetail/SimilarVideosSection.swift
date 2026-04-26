import SwiftUI

struct SimilarVideosSection: View {
    let videos: [Video]
    let isLoading: Bool
    var onVideoTap: ((String) -> Void)? = nil
    var onChannelTap: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
            } else if videos.isEmpty {
                Text(String(localized: "video_detail_no_similar"))
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .padding()
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(videos) { video in
                        Button {
                            onVideoTap?(video.youtubeId)
                        } label: {
                            SimilarVideoRow(video: video, onChannelTap: onChannelTap)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(video.title), \(video.channelName), \(video.durationStr)")
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

private struct SimilarVideoRow: View {
    let video: Video
    var onChannelTap: ((String) -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                AuthenticatedAsyncImage(url: video.thumbUrl)
                    .aspectRatio(16.0 / 9.0, contentMode: .fill)
                    .frame(width: 160)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Text(video.durationStr)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .padding(4)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(video.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(3)

                Button {
                    if !video.channelId.isEmpty {
                        onChannelTap?(video.channelId)
                    }
                } label: {
                    Text(video.channelName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    Label("\(video.viewCount)", systemImage: "eye")
                    if video.watched {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }
}
