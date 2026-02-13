import SwiftUI
import AVKit

struct VideoPlayerView: View {
    let asset: AVURLAsset?
    let startPosition: Double
    var onProgressUpdate: ((Double) -> Void)?
    var onDismiss: ((Double) -> Void)?

    @State private var player: AVPlayer?
    @State private var timeObserver: Any?
    @State private var hasSetInitialPosition = false

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .onDisappear {
                        let currentTime = player.currentTime().seconds
                        if currentTime.isFinite && currentTime > 0 {
                            onDismiss?(currentTime)
                        }
                        cleanup()
                    }
            } else {
                Color.black
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        ProgressView()
                            .tint(.white)
                    }
            }
        }
        .onAppear {
            setupPlayer()
        }
    }

    private func setupPlayer() {
        guard let asset, player == nil else { return }

        let playerItem = AVPlayerItem(asset: asset)
        let avPlayer = AVPlayer(playerItem: playerItem)

        // Seek to saved position
        if startPosition > 0 {
            let time = CMTime(seconds: startPosition, preferredTimescale: 600)
            avPlayer.seek(to: time)
        }

        // Progress observer every 10 seconds
        let interval = CMTime(seconds: 10, preferredTimescale: 600)
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let seconds = time.seconds
            if seconds.isFinite && seconds > 0 {
                onProgressUpdate?(seconds)
            }
        }

        self.player = avPlayer
        avPlayer.play()
    }

    private func cleanup() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        player?.pause()
        player = nil
    }
}
