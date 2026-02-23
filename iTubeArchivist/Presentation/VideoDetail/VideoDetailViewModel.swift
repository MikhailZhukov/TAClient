import Foundation
import AVFoundation

@Observable
final class VideoDetailViewModel {
    let videoId: String
    var video: Video?
    var comments: [Comment] = []
    var isLoading = true
    var isLoadingComments = false
    var errorMessage: String?
    var showDeleteDialog = false
    var selectedTab = 0
    var isPinned = false
    var isFullScreen = false

    private(set) var player: AVPlayer?
    private(set) var playerType: PlayerType = .avPlayer
    private(set) var vlcMediaURL: URL?
    var isPlaying: Bool { player != nil || vlcMediaURL != nil }

    private let videoRepository: VideoRepositoryProtocol
    private let authState: AuthState
    private let router: AppRouter
    private var timeObserver: Any?
    private var authProxy: AuthProxy?

    init(videoId: String, videoRepository: VideoRepositoryProtocol, authState: AuthState, router: AppRouter) {
        self.videoId = videoId
        self.videoRepository = videoRepository
        self.authState = authState
        self.router = router
    }

    var startPosition: Double {
        video?.position ?? 0
    }

    func startPlayback() {
        guard !isPlaying, let video else { return }

        let requiredPlayer = CodecSupport.requiredPlayer(for: video.streams)
        playerType = requiredPlayer

        switch requiredPlayer {
        case .avPlayer:
            startAVPlayback()
        case .vlcPlayer:
            Task { await startVLCPlayback() }
        }
    }

    // MARK: - AVPlayer

    private func startAVPlayback() {
        guard let video,
              let url = URL(string: video.mediaUrl),
              let token = authState.token else { return }

        let asset = AVURLAsset(
            url: url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Token \(token)"]]
        )
        let playerItem = AVPlayerItem(asset: asset, automaticallyLoadedAssetKeys: [.tracks, .duration])
        let avPlayer = AVPlayer(playerItem: playerItem)

        if startPosition > 0 {
            let time = CMTime(seconds: startPosition, preferredTimescale: 600)
            avPlayer.seek(to: time)
        }

        let progressQueue = DispatchQueue(label: "progress", qos: .utility)
        let interval = CMTime(seconds: 10, preferredTimescale: 600)
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: progressQueue) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            if seconds.isFinite && seconds > 0 {
                Task { await self.saveProgress(position: seconds) }
            }
        }

        self.player = avPlayer
        avPlayer.play()
    }

    // MARK: - VLC Player

    private func startVLCPlayback() async {
        guard let video,
              let url = URL(string: video.mediaUrl),
              let token = authState.token,
              let baseURL = authState.baseURL else { return }

        let proxy = AuthProxy(token: token, serverBaseURL: baseURL)
        do {
            try await proxy.start()
        } catch {
            return
        }

        guard let proxyURL = await proxy.proxyURL(for: url) else {
            await proxy.stop()
            return
        }

        self.authProxy = proxy
        self.vlcMediaURL = proxyURL
    }

    func onVLCTimeChanged(seconds: Double) {
        if seconds > 0 {
            Task { await saveProgress(position: seconds) }
        }
    }

    // MARK: - Stop

    func stopPlayback() {
        // Stop AVPlayer
        if let player {
            if let observer = timeObserver {
                player.removeTimeObserver(observer)
                timeObserver = nil
            }
            let seconds = player.currentTime().seconds
            if seconds.isFinite && seconds > 0 {
                Task { await saveProgress(position: seconds) }
            }
            player.pause()
            self.player = nil
        }

        // Stop VLC
        if vlcMediaURL != nil {
            vlcMediaURL = nil
            if let proxy = authProxy {
                authProxy = nil
                Task { await proxy.stop() }
            }
        }
    }

    func loadVideo() async {
        isLoading = true
        errorMessage = nil

        do {
            video = try await videoRepository.getVideo(id: videoId)
        } catch let error as AppError {
            if case .unauthorized = error {
                router.handleUnauthorized()
            } else {
                errorMessage = error.errorDescription
            }
        } catch {
            errorMessage = String(localized: "error_generic")
        }

        isLoading = false
    }

    func loadComments() async {
        isLoadingComments = true
        do {
            comments = try await videoRepository.getComments(videoId: videoId)
        } catch {}
        isLoadingComments = false
    }

    func saveProgress(position: Double) async {
        do {
            try await videoRepository.updateProgress(videoId: videoId, position: position)
        } catch {}
    }

    func deleteVideo() async {
        do {
            try await videoRepository.deleteVideo(id: videoId)
            router.goBack()
        } catch let error as AppError {
            if case .unauthorized = error {
                router.handleUnauthorized()
            }
        } catch {}
    }

    func deleteAndIgnoreVideo() async {
        do {
            try await videoRepository.deleteVideo(id: videoId)
            try await videoRepository.ignoreVideo(id: videoId)
            router.goBack()
        } catch let error as AppError {
            if case .unauthorized = error {
                router.handleUnauthorized()
            }
        } catch {}
    }

    func navigateToChannel(_ channelId: String) {
        router.navigate(to: .channelDetail(channelId: channelId))
    }
}
