import Foundation
import AVFoundation
import OSLog

private let logger = Logger(subsystem: "ru.mzhukov.iTubeArchivist", category: "VideoDetail")

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
    private var statusObservation: NSKeyValueObservation?
    private var stallObservation: NSKeyValueObservation?
    private var progressQueue = DispatchQueue(label: "progress", qos: .utility)
    private var authProxy: AuthProxy?
    private var cachingResourceLoader: CachingResourceLoader?
    private var lastVLCPosition: Double = 0
    private var lastCacheLogTime: CFAbsoluteTime = 0

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

        let asset: AVURLAsset
        if let cachingURL = CachingResourceLoader.cachingURL(from: url) {
            let loader = CachingResourceLoader(videoId: video.youtubeId, originalURL: url, token: token)
            let avAsset = AVURLAsset(url: cachingURL)
            avAsset.resourceLoader.setDelegate(loader, queue: loader.loaderQueue)
            self.cachingResourceLoader = loader
            asset = avAsset
        } else {
            asset = AVURLAsset(
                url: url,
                options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Token \(token)"]]
            )
        }

        let playerItem = AVPlayerItem(asset: asset, automaticallyLoadedAssetKeys: [.tracks, .duration])
        let avPlayer = AVPlayer(playerItem: playerItem)

        if startPosition > 0 {
            let time = CMTime(seconds: startPosition, preferredTimescale: 600)
            avPlayer.seek(to: time)
        }

        observePlayerStatus(avPlayer)

        let cachedVideoId = video.youtubeId
        let duration = video.duration
        let interval = CMTime(seconds: 10, preferredTimescale: 600)
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: progressQueue) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            if seconds.isFinite && seconds > 0 {
                self.logCacheHealth(videoId: cachedVideoId, playbackPosition: seconds, duration: Double(duration))
                Task {
                    await VideoCache.shared.updatePlaybackPosition(videoId: cachedVideoId, seconds: seconds, duration: Double(duration))
                    await self.saveProgress(position: seconds)
                }
            }
        }

        self.player = avPlayer
        avPlayer.play()
    }

    private func observePlayerStatus(_ avPlayer: AVPlayer) {
        let cachedVideoId = video?.youtubeId ?? videoId
        let duration = Double(video?.duration ?? 0)

        statusObservation = avPlayer.observe(\.timeControlStatus, options: [.new, .old]) { [weak self] player, _ in
            let status = player.timeControlStatus
            let reason = player.reasonForWaitingToPlay?.rawValue ?? "none"
            let pos = Int(player.currentTime().seconds)
            let bufferEmpty = player.currentItem?.isPlaybackBufferEmpty ?? false
            let keepUp = player.currentItem?.isPlaybackLikelyToKeepUp ?? false
            logger.info("timeControlStatus=\(status.rawValue) reason=\(reason) pos=\(pos)s bufferEmpty=\(bufferEmpty) keepUp=\(keepUp)")
            if status != .playing {
                self?.logCacheHealth(videoId: cachedVideoId, playbackPosition: Double(pos), duration: duration)
            }
        }
        stallObservation = avPlayer.currentItem?.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            let keepUp = item.isPlaybackLikelyToKeepUp
            let bufferEmpty = item.isPlaybackBufferEmpty
            let pos = Int(CMTimeGetSeconds(item.currentTime()))
            if !keepUp {
                logger.warning("Buffer underrun at \(pos)s, bufferEmpty=\(bufferEmpty)")
                self?.logCacheHealth(videoId: cachedVideoId, playbackPosition: Double(pos), duration: duration)
            }
        }
    }

    private func logCacheHealth(videoId: String, playbackPosition: Double, duration: Double) {
        // Throttle: max once per 3 seconds
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastCacheLogTime >= 3 else { return }
        lastCacheLogTime = now

        Task {
            guard let status = await VideoCache.shared.cacheStatus(videoId: videoId),
                  status.totalSize > 0 && duration > 0 else { return }

            let avgByterate = Double(status.totalSize) / duration
            let playbackByteOffset = playbackPosition * avgByterate
            let cachedBytes = status.endOffset - status.startOffset
            let cachePercent = Int(Double(cachedBytes) / Double(status.totalSize) * 100)

            // Account for gap: if playback is before cache start, ahead is negative
            let effectiveAhead: Double
            if playbackByteOffset < Double(status.startOffset) {
                effectiveAhead = -(Double(status.startOffset) - playbackByteOffset) / avgByterate
            } else {
                effectiveAhead = (Double(status.endOffset) - playbackByteOffset) / avgByterate
            }

            let level: String
            if effectiveAhead < 15 {
                level = "CRITICAL"
            } else if effectiveAhead < 30 {
                level = "LOW"
            } else {
                level = "OK"
            }

            logger.info("[Cache] \(level) pos=\(Int(playbackPosition))s ahead=\(String(format: "%.0f", effectiveAhead))s cached=\(cachePercent)% range=\(status.startOffset)-\(status.endOffset)/\(status.totalSize)")
        }
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
            lastVLCPosition = seconds
            Task { await saveProgress(position: seconds) }
        }
    }

    // MARK: - Stop

    func stopPlayback() {
        // Stop AVPlayer
        if let player {
            statusObservation?.invalidate()
            statusObservation = nil
            stallObservation?.invalidate()
            stallObservation = nil
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
            cachingResourceLoader = nil
            let vid = videoId
            Task { await VideoCache.shared.cancelPreload(videoId: vid) }
        }

        // Stop VLC
        if vlcMediaURL != nil {
            if lastVLCPosition > 0 {
                let position = lastVLCPosition
                Task { await saveProgress(position: position) }
            }
            vlcMediaURL = nil
            lastVLCPosition = 0
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

        // Start preloading for AVPlayer videos
        if let video,
           CodecSupport.requiredPlayer(for: video.streams) == .avPlayer,
           let url = URL(string: video.mediaUrl),
           let token = authState.token {
            await VideoCache.shared.startPreload(
                videoId: video.youtubeId,
                url: url,
                token: token,
                startPosition: video.position,
                duration: Double(video.duration)
            )
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
        } catch {
            logger.error("Failed to save position \(Int(position))s for \(self.videoId): \(error.localizedDescription)")
        }
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
