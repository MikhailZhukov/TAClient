import SwiftUI
import AVKit

struct VideoPlayerView: UIViewControllerRepresentable {
    let asset: AVURLAsset?
    let startPosition: Double
    var onProgressUpdate: ((Double) -> Void)?
    var onDismiss: ((Double) -> Void)?

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.allowsVideoFrameAnalysis = false
        context.coordinator.setup(controller: controller, asset: asset, startPosition: startPosition)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onProgressUpdate: onProgressUpdate, onDismiss: onDismiss)
    }

    final class Coordinator {
        private var onProgressUpdate: ((Double) -> Void)?
        private var onDismiss: ((Double) -> Void)?
        private var timeObserver: Any?
        private weak var player: AVPlayer?

        init(onProgressUpdate: ((Double) -> Void)?, onDismiss: ((Double) -> Void)?) {
            self.onProgressUpdate = onProgressUpdate
            self.onDismiss = onDismiss
        }

        func setup(controller: AVPlayerViewController, asset: AVURLAsset?, startPosition: Double) {
            guard let asset else { return }

            let playerItem = AVPlayerItem(asset: asset)
            let avPlayer = AVPlayer(playerItem: playerItem)
            controller.player = avPlayer
            self.player = avPlayer

            if startPosition > 0 {
                let time = CMTime(seconds: startPosition, preferredTimescale: 600)
                avPlayer.seek(to: time)
            }

            let interval = CMTime(seconds: 10, preferredTimescale: 600)
            timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                let seconds = time.seconds
                if seconds.isFinite && seconds > 0 {
                    self?.onProgressUpdate?(seconds)
                }
            }

            avPlayer.play()
        }

        func tearDown() {
            if let observer = timeObserver {
                player?.removeTimeObserver(observer)
                timeObserver = nil
            }
            let currentTime = player?.currentTime().seconds ?? 0
            if currentTime.isFinite && currentTime > 0 {
                onDismiss?(currentTime)
            }
            player?.pause()
        }

        deinit {
            if let observer = timeObserver {
                player?.removeTimeObserver(observer)
            }
        }
    }
}
