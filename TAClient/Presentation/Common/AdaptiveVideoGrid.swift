import SwiftUI

struct AdaptiveVideoGrid: View {
    let videos: [Video]
    var onVideoTap: (String) -> Void
    var onChannelTap: ((String) -> Void)? = nil
    var onNearEnd: (() -> Void)? = nil

    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 16)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(videos) { video in
                VideoCardView(video: video, onChannelTap: onChannelTap)
                    .onTapGesture {
                        onVideoTap(video.youtubeId)
                    }
                    .onAppear {
                        if let index = videos.firstIndex(where: { $0.id == video.id }),
                           index >= videos.count - 5 {
                            onNearEnd?()
                        }
                    }
            }
        }
        .padding(.horizontal)
    }
}
