import SwiftUI

private extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

struct AdaptiveVideoGrid: View {
    let videos: [Video]
    var onVideoTap: (String) -> Void
    var onChannelTap: ((String) -> Void)? = nil
    var onToggleWatched: ((String) -> Void)? = nil
    var onNearEnd: (() -> Void)? = nil

    var isSelecting: Bool = false
    var selectedIds: Set<String> = []
    var onEnterSelection: ((String) -> Void)? = nil
    var onToggleSelection: ((String) -> Void)? = nil

    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 16)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(videos) { video in
                VideoCardView(video: video, onChannelTap: isSelecting ? nil : onChannelTap)
                    .overlay {
                        if isSelecting {
                            ZStack(alignment: .topLeading) {
                                Color.black.opacity(selectedIds.contains(video.youtubeId) ? 0.15 : 0)
                                Image(systemName: selectedIds.contains(video.youtubeId) ? "checkmark.circle.fill" : "circle")
                                    .font(.title2)
                                    .foregroundStyle(selectedIds.contains(video.youtubeId) ? Color.accentColor : .white)
                                    .shadow(radius: 2)
                                    .padding(8)
                            }
                        }
                    }
                    .onTapGesture {
                        if isSelecting {
                            onToggleSelection?(video.youtubeId)
                        } else {
                            onVideoTap(video.youtubeId)
                        }
                    }
                    .if(onEnterSelection != nil) { view in
                        view.onLongPressGesture {
                            if !isSelecting {
                                onEnterSelection?(video.youtubeId)
                            }
                        }
                    }
                    .if(onEnterSelection == nil) { view in
                        view.contextMenu {
                            if let onToggleWatched {
                                Button {
                                    onToggleWatched(video.youtubeId)
                                } label: {
                                    Label(
                                        video.watched
                                            ? String(localized: "video_mark_unwatched")
                                            : String(localized: "video_mark_watched"),
                                        systemImage: video.watched ? "eye.slash" : "eye"
                                    )
                                }
                            }
                        }
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
