import Foundation
import AVFoundation
import OSLog

private nonisolated let logger = Logger(subsystem: "ru.mzhukov.TAClient", category: "VideoDetail")

@Observable
final class VideoDetailViewModel {
    let videoId: String
    var video: Video?
    var comments: [Comment] = []
    var similarVideos: [Video] = []
    var isLoading = true
    var isLoadingComments = false
    var isLoadingSimilar = false
    var errorMessage: String?
    var playbackError: String?
    var showDeleteDialog = false
    var showAddToPlaylistSheet = false
    var allPlaylists: [Playlist] = []
    var selectedTab = 0
    var isPinned = false
    var isFullScreen = false
    var isPiPActive = false
    var isViewVisible = true

    private(set) var player: AVPlayer?
    private(set) var playerType: PlayerType = .avPlayer
    private(set) var vlcMediaURL: URL?
    var isPlaying: Bool { player != nil || vlcMediaURL != nil }
    private(set) var isBuffering = false

    // SponsorBlock
    private(set) var skippedSegment: SponsorBlockSegment?
    var showSkipBanner = false
    private var skipBannerTask: Task<Void, Never>?
    private var skippedSegmentIds: Set<String> = []  // track skipped segments by "start-end" key

    private let videoRepository: VideoRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol?
    private let authState: AuthState
    private let router: AppRouter
    private let sponsorBlockSettings: SponsorBlockSettings
    private var timeObserver: Any?
    private var saveProgressObserver: Any?
    private var sponsorBlockObserver: Any?
    /// Tracks the last position persisted via `saveProgress`. Used to skip the
    /// 30s progress POST when the player is paused (time doesn't advance ⇒
    /// nothing new to save). `-1` means "no save yet".
    ///
    /// Read/written from both the MainActor and `progressQueue` (the 30s
    /// save time observer runs off the main thread to avoid MainActor churn
    /// every tick). Guarded by `progressStateLock` to avoid a Swift 6 data
    /// race on the scalar.
    @ObservationIgnored
    nonisolated(unsafe) private var lastSavedPosition: Double = -1
    /// Tracks the last position the 30s observer *attempted* to save — used
    /// to debounce the POST so we don't re-fire every tick. Distinct from
    /// `lastSavedPosition` (which only advances on success) so a failed
    /// POST doesn't mark the position as saved and lock out retries for
    /// another 30s. Same isolation story as `lastSavedPosition`.
    @ObservationIgnored
    nonisolated(unsafe) private var lastAttemptedSavePosition: Double = -1
    /// Companion scalar — same isolation story as `lastSavedPosition`.
    /// Throttles cache-health logs to once per 3s from the 1s UI observer.
    @ObservationIgnored
    nonisolated(unsafe) private var lastCacheLogTime: CFAbsoluteTime = 0
    /// Serialises access to the two scalars above across the MainActor ⇄
    /// `progressQueue` boundary. Cheap — only taken around trivial reads/
    /// writes on the periodic observers' hot path.
    nonisolated private let progressStateLock = NSLock()
    /// Nonisolated bag that owns every KVO + NotificationCenter observer token
    /// we register. Lets `deinit` tear observers down without a MainActor hop.
    /// `stopPlayback()` also calls `tearDown()` for the normal path.
    private let observerBag = ObserverBag()
    private let progressQueue = DispatchQueue(label: "ru.mzhukov.TAClient.player.progress", qos: .utility)
    private var authProxy: AuthProxy?
    private var cachingResourceLoader: CachingResourceLoader?
    private var lastVLCPosition: Double = 0
    private var lastVLCProgressSave: Date = .distantPast
    private var isUsingDirectAsset = false
    private var sessionCoordinator: PlayerSessionCoordinator?
    private var nowPlaying: NowPlayingController?

    init(videoId: String, videoRepository: VideoRepositoryProtocol, authState: AuthState, router: AppRouter, sponsorBlockSettings: SponsorBlockSettings = SponsorBlockSettings(), playlistRepository: PlaylistRepositoryProtocol? = nil) {
        self.videoId = videoId
        self.videoRepository = videoRepository
        self.playlistRepository = playlistRepository
        self.authState = authState
        self.router = router
        self.sponsorBlockSettings = sponsorBlockSettings
    }

    /// Safety net for abnormal teardown paths (e.g. VM released without
    /// `stopPlayback()` being called). `observerBag.tearDown()` is nonisolated
    /// and thread-safe, so deinit — which Swift 6 runs without implicit
    /// MainActor isolation — can invoke it directly. The bag is idempotent,
    /// so double tear-downs from `stopPlayback` + deinit are harmless.
    deinit {
        observerBag.tearDown()
    }

    var doubleTapToSeek: Bool { sponsorBlockSettings.doubleTapToSeek }
    var seekInterval: Int { sponsorBlockSettings.seekInterval }
    var seekFeedback: PlayerSeekFeedback?
    private var feedbackTask: Task<Void, Never>?

    func seekByInterval(forward: Bool) {
        let interval = Double(seekInterval)
        if let player {
            let current = player.currentTime().seconds
            guard current.isFinite else { return }
            let target = forward ? current + interval : max(0, current - interval)
            let time = CMTime(seconds: target, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            showSeekFeedback(forward: forward)
        } else if vlcMediaURL != nil {
            vlcSeekDelta = forward ? interval : -interval
            showSeekFeedback(forward: forward)
        }
    }

    private func showSeekFeedback(forward: Bool) {
        feedbackTask?.cancel()
        seekFeedback = PlayerSeekFeedback(direction: forward ? .forward : .backward)
        feedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.7))
            if !Task.isCancelled {
                seekFeedback = nil
            }
        }
    }

    func clearVLCSeekDelta() {
        vlcSeekDelta = nil
    }

    var vlcSeekDelta: Double?

    var startPosition: Double {
        video?.position ?? 0
    }

    func startPlayback() {
        guard !isPlaying && !isBuffering, let video else { return }

        isBuffering = true
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

    /// Orchestrates AVPlayer startup. Split into four behaviour-preserving
    /// helpers so the caller reads as a sequence of named steps instead of a
    /// 150-line block: asset → player item → observers → session + now-playing.
    private func startAVPlayback() {
        guard let video,
              let url = URL(string: video.mediaUrl),
              let token = authState.token else { return }

        let asset = configureAsset(url: url, videoId: video.youtubeId, token: token)
        let playerItem = AVPlayerItem(asset: asset, automaticallyLoadedAssetKeys: [.tracks, .duration])
        // Limit AVPlayer's internal forward buffer — our CacheStore already
        // holds up to 256MB, so without this cap AVPlayer duplicates data into
        // its own (unbounded) buffer and RAM grows unboundedly on large VBR
        // files. 30s is enough headroom for stall-free playback while keeping
        // the duplicate buffer bounded.
        playerItem.preferredForwardBufferDuration = 30
        let avPlayer = AVPlayer(playerItem: playerItem)

        if startPosition > 0 {
            let time = CMTime(seconds: startPosition, preferredTimescale: 600)
            avPlayer.seek(to: time)
        }

        registerPlayerObservers(player: avPlayer, videoId: video.youtubeId, duration: Double(video.duration))
        registerItemObservers(playerItem, videoId: video.youtubeId, duration: Double(video.duration))
        observeSponsorBlock(avPlayer)

        self.player = avPlayer
        avPlayer.play()

        configureSessionCoordinator()
        startNowPlayingController(for: avPlayer, video: video)
    }

    /// Builds the `AVURLAsset` according to the active route. Side effects
    /// (setting `isUsingDirectAsset`, retaining the caching loader) live here
    /// so the caller stays declarative.
    private func configureAsset(url: URL, videoId: String, token: String) -> AVURLAsset {
        if isAirPlayActive() {
            isUsingDirectAsset = true
            return AVURLAsset(
                url: url,
                options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Token \(token)"]]
            )
        }
        if let cachingURL = CachingResourceLoader.cachingURL(from: url) {
            let loader = CachingResourceLoader(videoId: videoId, originalURL: url, token: token)
            let avAsset = AVURLAsset(url: cachingURL)
            avAsset.resourceLoader.setDelegate(loader, queue: loader.loaderQueue)
            self.cachingResourceLoader = loader
            isUsingDirectAsset = false
            return avAsset
        }
        isUsingDirectAsset = true
        return AVURLAsset(
            url: url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Token \(token)"]]
        )
    }

    /// Registers time + timeControlStatus observers scoped to the player
    /// itself. Item-scoped observers (stall, status, failed-to-end,
    /// did-play-to-end) live in `registerItemObservers` so the AirPlay
    /// asset-swap path can re-register them on the replacement item.
    private func registerPlayerObservers(player avPlayer: AVPlayer, videoId cachedVideoId: String, duration: Double) {
        observePlayerStatus(avPlayer, videoId: cachedVideoId, duration: duration)

        // 1s UI observer: fast-cadence updates for the lock-screen scrubber
        // (nowPlaying.refresh) + cache-health telemetry. logCacheHealth has
        // its own 3s internal throttle so the extra ticks are cheap.
        let uiInterval = CMTime(seconds: 1, preferredTimescale: 600)
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: uiInterval, queue: progressQueue) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            if seconds.isFinite && seconds > 0 {
                self.logCacheHealth(videoId: cachedVideoId, playbackPosition: seconds, duration: duration)
                Task { @MainActor in
                    self.nowPlaying?.refresh()
                }
            }
        }
        // 30s save observer: persists progress and updates the preloader's
        // playback position. Debounced via `lastAttemptedSavePosition` and
        // `lastSavedPosition` — if the user is paused the time doesn't
        // advance, so we skip the POST entirely. Observer runs on
        // `progressQueue` (background) to avoid MainActor churn; the
        // debounce scalars are lock-guarded so the MainActor `stopPlayback`
        // reset (to -1) can't race with the tick read/write.
        //
        // We track `lastAttemptedSavePosition` separately from
        // `lastSavedPosition` so a failed POST doesn't get re-attempted on
        // every single tick (which would DDOS a flaky server) — but we also
        // don't want to pretend the save succeeded when it didn't, so
        // `lastSavedPosition` (which the ViewModel reads as "confirmed
        // persisted") only advances on success.
        let saveInterval = CMTime(seconds: 30, preferredTimescale: 600)
        saveProgressObserver = avPlayer.addPeriodicTimeObserver(forInterval: saveInterval, queue: progressQueue) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            guard seconds.isFinite && seconds > 0 else { return }
            self.progressStateLock.lock()
            let lastAttempted = self.lastAttemptedSavePosition
            let shouldSave = abs(seconds - lastAttempted) >= 1
            if shouldSave {
                self.lastAttemptedSavePosition = seconds
            }
            self.progressStateLock.unlock()
            guard shouldSave else { return }
            VideoCachePreloader.shared.store.updatePlaybackPosition(videoId: cachedVideoId, seconds: seconds, duration: duration)
            Task { [weak self] in
                guard let self else { return }
                let attemptedPosition = seconds
                let ok = await self.saveProgress(position: attemptedPosition)
                if ok {
                    self.progressStateLock.withLock {
                        // Only advance `lastSavedPosition` if this save's target
                        // is still the most-recent confirmed position — avoids
                        // rewinding if a later save completed first.
                        if attemptedPosition > self.lastSavedPosition {
                            self.lastSavedPosition = attemptedPosition
                        }
                    }
                } else {
                    // POST failed — revert the "attempted" marker to the
                    // last confirmed save so the next tick retries instead
                    // of being debounced for another 30s. Only do so when
                    // the current `lastAttemptedSavePosition` is still OUR
                    // attempt: if a later tick already advanced it (and
                    // possibly succeeded), reverting would clobber the
                    // in-flight / successful newer save.
                    self.progressStateLock.withLock {
                        if self.lastAttemptedSavePosition == attemptedPosition {
                            self.lastAttemptedSavePosition = self.lastSavedPosition
                        }
                    }
                }
            }
        }
    }

    /// Registers all per-AVPlayerItem observers (stall KVO, item-status KVO,
    /// failed-to-play-to-end notification, did-play-to-end notification).
    /// Shared by initial startup and the AirPlay asset-swap path so the
    /// replacement item gets the same treatment — without this, playback
    /// failure / natural end / item-status-failed events on the direct-
    /// streaming path after AirPlay activation would go unhandled.
    ///
    /// Over-registration is safe: observer tokens live in `observerBag` and
    /// `tearDown()` invalidates all of them at stopPlayback time; `object:`-
    /// scoped notification tokens for prior items are harmless once those
    /// items deallocate. AirPlay activation is rare enough that the tiny
    /// duplicate observer cost is acceptable.
    private func registerItemObservers(_ item: AVPlayerItem, videoId cachedVideoId: String, duration: Double) {
        let stallToken = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            if !item.isPlaybackLikelyToKeepUp {
                let pos = Int(CMTimeGetSeconds(item.currentTime()))
                logger.warning("Buffer underrun at \(pos)s, bufferEmpty=\(item.isPlaybackBufferEmpty)")
                self?.logCacheHealth(videoId: cachedVideoId, playbackPosition: Double(pos), duration: duration)
            }
        }
        observerBag.addKVO(stallToken)

        let itemStatusToken = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? String(localized: "player_error_generic")
            Task { @MainActor [weak self] in
                self?.handlePlaybackFailure(message: message)
            }
        }
        observerBag.addKVO(itemStatusToken)

        observeFailedToPlayToEnd(item)
        observeDidPlayToEnd(item)
    }

    /// Creates the `PlayerSessionCoordinator` and wires its five callbacks to
    /// the VM. Extracted from `startAVPlayback` purely to shrink the caller —
    /// lifecycle remains 1:1 with playback (stopPlayback nils the coordinator).
    private func configureSessionCoordinator() {
        let coordinator = PlayerSessionCoordinator()
        coordinator.onInterruptionBegan = { [weak self] in
            self?.player?.pause()
        }
        coordinator.onInterruptionEnded = { [weak self] shouldResume in
            guard let self else { return }
            if shouldResume {
                self.player?.play()
            }
            self.nowPlaying?.refresh()
        }
        coordinator.onHeadphonesUnplugged = { [weak self] in
            self?.player?.pause()
        }
        coordinator.onAirPlayBecameActive = { [weak self] in
            self?.handleAirPlayBecameActive()
        }
        coordinator.onMediaServicesReset = { [weak self] in
            guard let self else { return }
            self.stopPlayback()
            self.playbackError = String(localized: "player_error_media_reset")
        }
        coordinator.start()
        self.sessionCoordinator = coordinator
    }

    /// Instantiates `NowPlayingController` bound to `avPlayer` and `video`,
    /// wiring play/pause/seek callbacks. Extracted from `startAVPlayback` so
    /// the controller can be rebuilt (e.g. when `seekInterval` changes) without
    /// tearing down the entire playback session.
    private func startNowPlayingController(for avPlayer: AVPlayer, video: Video) {
        let controller = NowPlayingController(
            player: avPlayer,
            video: video,
            imageCache: ImageCache.shared,
            seekInterval: sponsorBlockSettings.seekInterval,
            authToken: authState.token,
            onPlay: { [weak self] in
                self?.player?.play()
                self?.nowPlaying?.refresh()
            },
            onPause: { [weak self] in
                self?.player?.pause()
                self?.nowPlaying?.refresh()
            },
            onSeek: { [weak self] positionTime in
                guard let self, let player = self.player else { return }
                let time = CMTime(seconds: positionTime, preferredTimescale: 600)
                player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                self.nowPlaying?.refresh()
            }
        )
        controller.start()
        self.nowPlaying = controller
    }

    /// Called from the view layer when `sponsorBlockSettings.seekInterval`
    /// changes. Rebuilds the now-playing controller with the new interval —
    /// simpler than adding a mutator for a rare event.
    func seekIntervalDidChange() {
        guard let player, let video else { return }
        nowPlaying?.stop()
        nowPlaying = nil
        startNowPlayingController(for: player, video: video)
    }

    /// Swap the current asset for a direct-auth asset when AirPlay becomes
    /// active — receivers cannot resolve the custom `itacache://` scheme, and
    /// Apple does not allow passing Authorization headers with AirPlay.
    private func handleAirPlayBecameActive() {
        guard !isUsingDirectAsset,
              let player, let video,
              let url = URL(string: video.mediaUrl),
              let token = authState.token else { return }

        let currentTime = player.currentTime()

        let asset = AVURLAsset(
            url: url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Token \(token)"]]
        )
        let item = AVPlayerItem(asset: asset, automaticallyLoadedAssetKeys: [.tracks, .duration])
        player.replaceCurrentItem(with: item)
        player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero)
        cachingResourceLoader = nil
        isUsingDirectAsset = true

        // Re-register every per-item observer on the replacement item. The
        // prior item's notification observers are scoped to that object and
        // will never fire again; the item `.status` and stall KVOs are also
        // bound to the old item. `registerItemObservers` tolerates the
        // duplicate KVO registration — see its docstring for the rationale.
        registerItemObservers(item, videoId: video.youtubeId, duration: Double(video.duration))

        logger.info("AirPlay active: switched to direct streaming")
    }

    private func observeFailedToPlayToEnd(_ item: AVPlayerItem) {
        let token = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let message = error?.localizedDescription ?? String(localized: "player_error_network")
            Task { @MainActor in self.handlePlaybackFailure(message: message) }
        }
        observerBag.addNotification(token)
    }

    /// Observes natural end-of-playback so we can force a final `saveProgress`
    /// at `video.duration` (the 30s save observer might skip the last save if
    /// the tick fires inside its 1-second debounce) and refresh the lock-screen
    /// scrubber. Leaves the player paused — default `actionAtItemEnd` is
    /// `.pause`.
    private func observeDidPlayToEnd(_ item: AVPlayerItem) {
        let token = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.handleDidPlayToEnd() }
        }
        observerBag.addNotification(token)
    }

    @MainActor
    func handleDidPlayToEnd() {
        guard let video else { return }
        let finalPosition = Double(video.duration)
        progressStateLock.lock()
        lastSavedPosition = finalPosition
        lastAttemptedSavePosition = finalPosition
        progressStateLock.unlock()
        nowPlaying?.refresh()
        Task { await self.saveProgress(position: finalPosition) }
    }

    @MainActor
    func handlePlaybackFailure(message: String) {
        playbackError = message
        stopPlayback()
    }

    /// Observes player-scoped state transitions (`timeControlStatus`). Item-
    /// scoped observers (stall KVO, item-status KVO) live in
    /// `registerItemObservers` so the AirPlay swap path can re-register them
    /// on the replacement item without duplicating this logic.
    private func observePlayerStatus(_ avPlayer: AVPlayer, videoId cachedVideoId: String, duration: Double) {
        let statusToken = avPlayer.observe(\.timeControlStatus, options: [.new, .old]) { [weak self] player, _ in
            let status = player.timeControlStatus
            let reason = player.reasonForWaitingToPlay?.rawValue ?? "none"
            let pos = Int(player.currentTime().seconds)
            let bufferEmpty = player.currentItem?.isPlaybackBufferEmpty ?? false
            let keepUp = player.currentItem?.isPlaybackLikelyToKeepUp ?? false
            logger.info("timeControlStatus=\(status.rawValue) reason=\(reason) pos=\(pos)s bufferEmpty=\(bufferEmpty) keepUp=\(keepUp)")
            if status == .playing {
                guard let self else { return }
                Task { @MainActor in
                    self.isBuffering = false
                    // Refresh after stall recovery so the lock-screen scrubber
                    // reflects that we're playing again rather than buffering.
                    self.nowPlaying?.refresh()
                }
            } else {
                self?.logCacheHealth(videoId: cachedVideoId, playbackPosition: Double(pos), duration: duration)
            }
        }
        observerBag.addKVO(statusToken)
    }

    /// Nonisolated to permit calls from the `progressQueue` time observer
    /// (1s UI tick) without a MainActor hop on the hot path. The only mutable
    /// state it touches is `lastCacheLogTime`, guarded by `progressStateLock`.
    nonisolated private func logCacheHealth(videoId: String, playbackPosition: Double, duration: Double) {
        // Throttle: max once per 3 seconds. Lock-guarded read/write so the
        // MainActor status observer and the progressQueue periodic observer
        // can't race on the scalar.
        let now = CFAbsoluteTimeGetCurrent()
        progressStateLock.lock()
        let should = (now - lastCacheLogTime) >= 3
        if should {
            lastCacheLogTime = now
        }
        progressStateLock.unlock()
        guard should else { return }

        // Sync read — store is NSLock-guarded, no executor hop.
        guard let status = VideoCachePreloader.shared.store.cacheStatus(videoId: videoId),
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

    // MARK: - AirPlay

    private func isAirPlayActive() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
    }

    func handlePiPStopped() {
        isPiPActive = false
        if !isViewVisible {
            stopPlayback()
        }
    }

    // MARK: - SponsorBlock

    private func observeSponsorBlock(_ avPlayer: AVPlayer) {
        let segments = activeSegments()
        guard !segments.isEmpty else { return }

        let interval = CMTime(seconds: 1, preferredTimescale: 600)
        sponsorBlockObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            guard seconds.isFinite, seconds > 0 else { return }
            self.checkSponsorBlockSkip(currentTime: seconds, player: avPlayer)
        }
    }

    private func checkSponsorBlockSkip(currentTime: Double, player: AVPlayer) {
        let segments = activeSegments()
        for segment in segments {
            let key = segmentKey(segment)
            if currentTime >= segment.startTime && currentTime < segment.endTime && !skippedSegmentIds.contains(key) {
                skippedSegmentIds.insert(key)
                let seekTime = CMTime(seconds: segment.endTime, preferredTimescale: 600)
                player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
                nowPlaying?.refresh()
                logger.info("SponsorBlock: skipped \(segment.category.rawValue) [\(String(format: "%.1f", segment.startTime))s-\(String(format: "%.1f", segment.endTime))s]")
                showSkipNotification(segment)
                break
            }
        }
    }

    func checkSponsorBlockSkipVLC(currentTime: Double) {
        let segments = activeSegments()
        for segment in segments {
            let key = segmentKey(segment)
            if currentTime >= segment.startTime && currentTime < segment.endTime && !skippedSegmentIds.contains(key) {
                skippedSegmentIds.insert(key)
                logger.info("SponsorBlock: VLC skip \(segment.category.rawValue) [\(String(format: "%.1f", segment.startTime))s-\(String(format: "%.1f", segment.endTime))s]")
                showSkipNotification(segment)
                break
            }
        }
    }

    var vlcSponsorBlockSeekTarget: Double? {
        let segments = activeSegments()
        guard let time = lastVLCPosition > 0 ? lastVLCPosition : nil else { return nil }
        for segment in segments {
            let key = segmentKey(segment)
            if time >= segment.startTime && time < segment.endTime && !skippedSegmentIds.contains(key) {
                return segment.endTime
            }
        }
        return nil
    }

    func activeSegments() -> [SponsorBlockSegment] {
        guard let video else { return [] }
        let enabled = sponsorBlockSettings.enabledCategories()
        guard !enabled.isEmpty else { return [] }
        return video.sponsorblock.filter { enabled.contains($0.category) }
    }

    private func showSkipNotification(_ segment: SponsorBlockSegment) {
        skippedSegment = segment
        showSkipBanner = true
        skipBannerTask?.cancel()
        skipBannerTask = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled {
                showSkipBanner = false
                skippedSegment = nil
            }
        }
    }

    func undoSkip() {
        guard let segment = skippedSegment else { return }
        let key = segmentKey(segment)
        skippedSegmentIds.remove(key)
        showSkipBanner = false
        skipBannerTask?.cancel()

        let seekTime = CMTime(seconds: segment.startTime, preferredTimescale: 600)
        if let player {
            player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        // For VLC, the caller handles seeking
        skippedSegment = nil
    }

    private func segmentKey(_ segment: SponsorBlockSegment) -> String {
        "\(segment.startTime)-\(segment.endTime)"
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
            if isBuffering { isBuffering = false }
            lastVLCPosition = seconds
            checkSponsorBlockSkipVLC(currentTime: seconds)
            let now = Date()
            if now.timeIntervalSince(lastVLCProgressSave) >= 10 {
                lastVLCProgressSave = now
                Task { await saveProgress(position: seconds) }
            }
        }
    }

    // MARK: - Stop

    func stopPlayback() {
        isBuffering = false
        isPiPActive = false
        skipBannerTask?.cancel()
        showSkipBanner = false
        skippedSegment = nil
        skippedSegmentIds.removeAll()
        nowPlaying?.stop()
        nowPlaying = nil
        sessionCoordinator?.stop()
        sessionCoordinator = nil
        isUsingDirectAsset = false
        // Single call tears down every KVO + notification token registered
        // during startAVPlayback / observePlayerStatus / observeFailedToPlayToEnd
        // / handleAirPlayBecameActive. Idempotent — deinit may also call it.
        observerBag.tearDown()
        // Stop AVPlayer
        if let player {
            if let observer = timeObserver {
                player.removeTimeObserver(observer)
                timeObserver = nil
            }
            if let observer = saveProgressObserver {
                player.removeTimeObserver(observer)
                saveProgressObserver = nil
            }
            if let observer = sponsorBlockObserver {
                player.removeTimeObserver(observer)
                sponsorBlockObserver = nil
            }
            // Snapshot the last-saved position under the lock before we reset
            // it, so the debounce check below (MainActor here, observer on
            // progressQueue) doesn't race on the scalar. `handleDidPlayToEnd`
            // will have just written `video.duration`; skip the second POST
            // if we're within 0.5s of that.
            progressStateLock.lock()
            let lastSaved = lastSavedPosition
            lastSavedPosition = -1
            lastAttemptedSavePosition = -1
            progressStateLock.unlock()
            let seconds = player.currentTime().seconds
            if seconds.isFinite && seconds > 0 && seconds > lastSaved + 0.5 {
                Task { await saveProgress(position: seconds) }
            }
            player.pause()
            self.player = nil
            cachingResourceLoader = nil
            let vid = videoId
            Task { await VideoCachePreloader.shared.cancelPreload(videoId: vid) }
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
        } catch {
            router.handleError(error, errorMessage: &errorMessage)
        }

        // Start preloading for AVPlayer videos
        if let video,
           CodecSupport.requiredPlayer(for: video.streams) == .avPlayer,
           let url = URL(string: video.mediaUrl),
           let token = authState.token {
            await VideoCachePreloader.shared.startPreloadWithRetry(
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

    func loadSimilarVideos() async {
        guard similarVideos.isEmpty else { return }
        isLoadingSimilar = true
        do {
            similarVideos = try await videoRepository.getSimilarVideos(videoId: videoId)
        } catch {}
        isLoadingSimilar = false
    }

    /// Persists the current playback position. Returns `true` on success so
    /// callers (notably the 30s progress observer) can advance the
    /// "confirmed saved" cursor only when the POST actually landed; a
    /// failed POST leaves `lastSavedPosition` behind so the next tick
    /// retries instead of being debounced out.
    @discardableResult
    func saveProgress(position: Double) async -> Bool {
        do {
            try await videoRepository.updateProgress(videoId: videoId, position: position)
            return true
        } catch {
            logger.error("Failed to save position \(Int(position))s for \(self.videoId): \(error.localizedDescription)")
            return false
        }
    }

    func toggleWatched() async {
        guard var updatedVideo = video else { return }
        let newValue = !updatedVideo.watched
        updatedVideo.watched = newValue
        video = updatedVideo

        do {
            try await videoRepository.setWatched(videoId: videoId, isWatched: newValue)
            router.markWatchedChanged(videoId, isWatched: newValue)
        } catch {
            updatedVideo.watched = !newValue
            video = updatedVideo
            router.handleError(error, errorMessage: &errorMessage)
        }
    }

    func deleteVideo() async {
        do {
            try await videoRepository.deleteVideo(id: videoId)
            stopPlayback()
            await VideoCachePreloader.shared.clear()
            router.markVideoDeleted(videoId)
            router.goBack()
        } catch {
            router.handleError(error, errorMessage: &errorMessage)
        }
    }

    func deleteAndIgnoreVideo() async {
        do {
            try await videoRepository.deleteVideo(id: videoId)
            try await videoRepository.ignoreVideo(id: videoId)
            stopPlayback()
            await VideoCachePreloader.shared.clear()
            router.markVideoDeleted(videoId)
            router.goBack()
        } catch {
            router.handleError(error, errorMessage: &errorMessage)
        }
    }

    func navigateToChannel(_ channelId: String) {
        router.navigate(to: .channelDetail(channelId: channelId))
    }

    func navigateToVideo(_ videoId: String) {
        router.navigate(to: .videoDetail(videoId: videoId))
    }

    // MARK: - Playlists

    func loadPlaylists() async {
        guard let playlistRepository else { return }
        var playlists: [Playlist] = []
        if let custom = try? await playlistRepository.getPlaylists(page: 1, type: "custom") {
            playlists.append(contentsOf: custom.playlists)
        }
        if let regular = try? await playlistRepository.getPlaylists(page: 1, type: "regular") {
            playlists.append(contentsOf: regular.playlists)
        }
        allPlaylists = playlists
    }

    func createPlaylistAndAddVideo(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let playlistRepository else { return }
        do {
            let playlist = try await playlistRepository.createCustomPlaylist(name: trimmed)
            try await playlistRepository.addVideoToPlaylist(playlistId: playlist.playlistId, videoId: videoId)
            allPlaylists.insert(playlist, at: 0)
            video?.playlists.append(playlist.playlistId)
        } catch {
            router.handleError(error, errorMessage: &errorMessage)
        }
    }

    func isVideoInPlaylist(_ playlistId: String) -> Bool {
        video?.playlists.contains(playlistId) ?? false
    }

    func toggleVideoInPlaylist(_ playlistId: String) async {
        guard let playlistRepository, var updatedVideo = video else { return }

        if isVideoInPlaylist(playlistId) {
            updatedVideo.playlists.removeAll { $0 == playlistId }
            video = updatedVideo
            do {
                try await playlistRepository.removeVideoFromPlaylist(playlistId: playlistId, videoId: videoId)
            } catch {
                updatedVideo.playlists.append(playlistId)
                video = updatedVideo
                router.handleError(error, errorMessage: &errorMessage)
            }
        } else {
            updatedVideo.playlists.append(playlistId)
            video = updatedVideo
            do {
                try await playlistRepository.addVideoToPlaylist(playlistId: playlistId, videoId: videoId)
            } catch {
                updatedVideo.playlists.removeAll { $0 == playlistId }
                video = updatedVideo
                router.handleError(error, errorMessage: &errorMessage)
            }
        }
    }
}
