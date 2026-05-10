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
    private var tailObserver: Any?
    private var freezeWatchdogTask: Task<Void, Never>?
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
    /// Last currentTime sample seen by the 1Hz observer — used to detect
    /// unexpected backward jumps (bug 1: tail replay). Same isolation as the
    /// other progressQueue-touched scalars.
    @ObservationIgnored
    nonisolated(unsafe) private var lastTickPosition: Double = -1
    /// Wallclock time of the most recent explicit `seek()` call we made (any
    /// reason). The backward-jump detector ignores jumps that happen within
    /// 1s of an explicit seek — those are intentional, not a replay bug.
    @ObservationIgnored
    nonisolated(unsafe) private var lastExplicitSeekAt: CFAbsoluteTime = VideoDetailViewModel.resetExplicitSeekTimestamp()

    /// Reset value for `lastExplicitSeekAt` on `stopPlayback()` paths. Returns
    /// `CFAbsoluteTimeGetCurrent()` — never `0` (which corresponds to the
    /// CFAbsoluteTime epoch 2001-01-01 and produces a bogus
    /// `[TailReplay] sinceLastSeek=800005224.34s` ~25-year diagnostic skew).
    /// Extracted as a static helper so the contract is testable without
    /// having to wire a real `AVPlayer` into a VM SUT just to drive
    /// `stopPlayback`'s `if let player` branch.
    nonisolated static func resetExplicitSeekTimestamp() -> CFAbsoluteTime {
        CFAbsoluteTimeGetCurrent()
    }
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
            recordSeek("[Seek] reason=seekByInterval forward=\(forward) from=\(String(format: "%.2f", current))s to=\(String(format: "%.2f", target))s")
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
        logger.notice("[Start] actionAtItemEnd=\(avPlayer.actionAtItemEnd.rawValue) startPosition=\(self.startPosition)s duration=\(video.duration)s isUsingDirectAsset=\(self.isUsingDirectAsset)")

        if startPosition > 0 {
            let time = CMTime(seconds: startPosition, preferredTimescale: 600)
            recordSeek("[Seek] reason=startup to=\(self.startPosition)s")
            avPlayer.seek(to: time)
        }

        registerPlayerObservers(player: avPlayer, videoId: video.youtubeId, duration: Double(video.duration))
        registerItemObservers(playerItem, videoId: video.youtubeId, duration: Double(video.duration))
        observeSponsorBlock(avPlayer)
        registerTailObserver(player: avPlayer, duration: Double(video.duration))
        startFreezeWatchdog()

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
                self.detectBackwardJump(current: seconds)
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
        saveProgressObserver = avPlayer.addPeriodicTimeObserver(forInterval: saveInterval, queue: progressQueue) { [weak self, weak avPlayer] time in
            guard let self, let avPlayer else { return }
            let seconds = time.seconds
            self.progressStateLock.lock()
            let lastAttempted = self.lastAttemptedSavePosition
            let shouldSave = VideoDetailViewModel.shouldSaveProgress(
                rate: avPlayer.rate,
                seconds: seconds,
                lastAttempted: lastAttempted
            )
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
            if item.status == .readyToPlay {
                Task { @MainActor [weak self] in
                    guard let self, let currentItem = self.player?.currentItem else { return }
                    await self.logVideoFormat(currentItem)
                }
            }
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? String(localized: "player_error_generic")
            Task { @MainActor [weak self] in
                self?.handlePlaybackFailure(message: message)
            }
        }
        observerBag.addKVO(itemStatusToken)

        observeFailedToPlayToEnd(item)
        observeDidPlayToEnd(item)
        observeAVLogs(item)
    }

    /// Subscribes to AVPlayerItem's native access + error log streams. Each
    /// new entry is mirrored into our Logger so the captured log shows
    /// AVPlayer's own diagnostic stream alongside our app-level events.
    /// Critical for diagnosing AV1 decoder issues (errorLog often surfaces
    /// CoreMediaErrorDomain codes the public APIs hide).
    private func observeAVLogs(_ item: AVPlayerItem) {
        let accessToken = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newAccessLogEntryNotification,
            object: item,
            queue: .main
        ) { [weak item] _ in
            guard let item, let event = item.accessLog()?.events.last else { return }
            logger.info("[AVAccess] indicatedBitrate=\(Int(event.indicatedBitrate)) observedBitrate=\(Int(event.observedBitrate)) stalls=\(event.numberOfStalls) droppedFrames=\(event.numberOfDroppedVideoFrames) durationWatched=\(String(format: "%.1f", event.durationWatched)) playbackType=\(event.playbackType ?? "?")")
        }
        observerBag.addNotification(accessToken)

        let errorToken = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newErrorLogEntryNotification,
            object: item,
            queue: .main
        ) { [weak item] _ in
            guard let item, let event = item.errorLog()?.events.last else { return }
            logger.error("[AVError] code=\(event.errorStatusCode) domain=\(event.errorDomain, privacy: .public) comment=\(event.errorComment ?? "?", privacy: .public)")
        }
        observerBag.addNotification(errorToken)
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
                recordSeek("[Seek] reason=nowPlayingRemote to=\(String(format: "%.2f", positionTime))s")
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
        recordSeek("[Seek] reason=airplaySwap to=\(String(format: "%.2f", currentTime.seconds))s")
        player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero)
        cachingResourceLoader = nil
        isUsingDirectAsset = true

        // Re-register every per-item observer on the replacement item. The
        // prior item's notification observers are scoped to that object and
        // will never fire again; the item `.status` and stall KVOs are also
        // bound to the old item. `registerItemObservers` tolerates the
        // duplicate KVO registration — see its docstring for the rationale.
        registerItemObservers(item, videoId: video.youtubeId, duration: Double(video.duration))

        logger.notice("AirPlay active: switched to direct streaming")
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
        let actualTime = player?.currentTime().seconds ?? -1
        let action = player?.actionAtItemEnd.rawValue ?? -1
        let rate = player?.rate ?? 0
        logger.notice("[End] DidPlayToEnd currentTime=\(actualTime, format: .fixed(precision: 2))s declaredDuration=\(finalPosition)s actionAtItemEnd=\(action) rate=\(rate)")
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
            logger.notice("timeControlStatus=\(status.rawValue) reason=\(reason, privacy: .public) pos=\(pos)s bufferEmpty=\(bufferEmpty) keepUp=\(keepUp)")
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

    // MARK: - Diagnostics (temporary instrumentation)
    // TODO(v0.9.1 cleanup): remove with diagnostic instrumentation

    /// Tail-end periodic observer firing every 0.5s but logging only when the
    /// playhead is within the last 5 seconds of the video. Gives a per-tick
    /// timeline of end-of-stream — surfaces reverse seeks / replay loops.
    private func registerTailObserver(player avPlayer: AVPlayer, duration: Double) {
        guard duration > 0 else { return }
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        tailObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: progressQueue) { [weak self] time in
            guard let self, let player = self.player else { return }
            let seconds = time.seconds
            guard seconds.isFinite, seconds > duration - 5 else { return }
            let rate = player.rate
            let status = player.timeControlStatus.rawValue
            let item = player.currentItem
            let keepUp = item?.isPlaybackLikelyToKeepUp ?? false
            let bufferEmpty = item?.isPlaybackBufferEmpty ?? false
            logger.info("[Tail] t=\(String(format: "%.2f", seconds))s/\(String(format: "%.2f", duration))s rate=\(rate) status=\(status) keepUp=\(keepUp) bufferEmpty=\(bufferEmpty)")
        }
    }

    /// 1Hz watchdog that detects video freezes (currentTime not advancing
    /// while rate>0 and timeControlStatus==.playing). Logs FREEZE_DETECTED
    /// with a full state dump after 3 consecutive stalled samples.
    private func startFreezeWatchdog() {
        freezeWatchdogTask?.cancel()
        freezeWatchdogTask = Task { @MainActor [weak self] in
            var lastTime: Double = -1
            var stuckCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, let player = self.player else { return }
                let current = player.currentTime().seconds
                let rate = player.rate
                let status = player.timeControlStatus
                let isPlaying = (status == .playing && rate > 0)
                guard isPlaying, current.isFinite else {
                    lastTime = current
                    stuckCount = 0
                    continue
                }
                if lastTime >= 0 && abs(current - lastTime) < 0.3 {
                    stuckCount += 1
                } else {
                    stuckCount = 0
                }
                if stuckCount == 3 {
                    let item = player.currentItem
                    let bufferEmpty = item?.isPlaybackBufferEmpty ?? false
                    let keepUp = item?.isPlaybackLikelyToKeepUp ?? false
                    let ranges = item?.loadedTimeRanges
                        .map { $0.timeRangeValue }
                        .map { String(format: "[%.1f+%.1f]", $0.start.seconds, $0.duration.seconds) }
                        .joined(separator: ",") ?? "none"
                    let lastErr = item?.errorLog()?.events.last
                    let errStr = lastErr.map { "code=\($0.errorStatusCode) domain=\($0.errorDomain) comment=\($0.errorComment ?? "?")" } ?? "none"
                    let itemErr = item?.error?.localizedDescription ?? "nil"
                    logger.error("[Freeze] FREEZE_DETECTED at \(current, format: .fixed(precision: 2))s rate=\(rate) bufferEmpty=\(bufferEmpty) keepUp=\(keepUp) ranges=\(ranges, privacy: .public) item.error=\(itemErr, privacy: .public) lastErrorLog=\(errStr, privacy: .public)")
                }
                lastTime = current
            }
        }
    }

    /// Logs a seek event at .notice (persisted to disk in the iOS log store
    /// for ~24h) and stamps `lastExplicitSeekAt` so the backward-jump detector
    /// can suppress legitimate user/system seeks. The `.public` privacy hint
    /// keeps the message readable in `log show` / sysdiagnose extracts.
    nonisolated private func recordSeek(_ message: String) {
        progressStateLock.lock()
        lastExplicitSeekAt = CFAbsoluteTimeGetCurrent()
        progressStateLock.unlock()
        logger.notice("\(message, privacy: .public)")
    }

    /// Detects unexpected backward jumps in playback position — the signature
    /// of bug 1 (tail replay). Called from the 1Hz UI observer on every tick.
    /// Suppresses jumps within 1.0s of an explicit seek (legitimate user
    /// scrub, sponsor-block skip, lock-screen scrubber). Logs at `.error` so
    /// the event persists to disk and is recoverable via `log show` /
    /// sysdiagnose without needing Console.app to be running at the moment.
    nonisolated private func detectBackwardJump(current: Double) {
        progressStateLock.lock()
        let prev = lastTickPosition
        let sinceSeek = CFAbsoluteTimeGetCurrent() - lastExplicitSeekAt
        lastTickPosition = current
        progressStateLock.unlock()
        guard prev >= 0 else { return }
        let delta = prev - current
        guard delta > 0.3, sinceSeek > 1.0 else { return }
        logger.error("[TailReplay] BACKWARD_JUMP from=\(prev, format: .fixed(precision: 2))s to=\(current, format: .fixed(precision: 2))s delta=\(delta, format: .fixed(precision: 2))s sinceLastSeek=\(sinceSeek, format: .fixed(precision: 2))s")
    }

    /// Decides whether the 30s save observer should issue a `saveProgress` POST.
    ///
    /// Three conditions must hold:
    /// - `seconds` is finite and positive (defensive against NaN/negative samples)
    /// - `rate > 0` (player is actively playing; suppresses saves during pause and
    ///   AVPlayer's internal auto-seek-back at end-of-stream — see the comment block
    ///   in the save observer for the bug this prevents)
    /// - `|seconds - lastAttempted| >= 1` (debounce: skip ticks within 1s of the
    ///   last attempted save to avoid spamming the server with sub-second updates)
    ///
    /// `rate > 0` is the load-bearing new check. Pause + AVPlayer auto-seek-back
    /// both have rate==0 and would otherwise race with `handleDidPlayToEnd`'s
    /// final-save-of-duration, often winning and storing a regressed position
    /// (~6s before duration) on the server. NaN rate evaluates `rate > 0` as
    /// false, which correctly classifies a not-yet-loaded player as "not playing".
    ///
    /// **Stall behavior** (`timeControlStatus == .waitingToPlayAtSpecifiedRate`,
    /// e.g. buffer underrun on slow networks): rate transiently drops to 0.
    /// The periodic time observer fires only on time advance, rate change, or
    /// seek — during a stall, time doesn't advance, so the observer fires once
    /// at stall-entry (rate=0, save skipped) and once at stall-exit (rate=1,
    /// save proceeds). Saves are delayed by the stall duration but not lost:
    /// if the user closes the app mid-stall, `stopPlayback` issues a final
    /// save (guarded by `seconds > lastSaved + 0.5`) covering the gap.
    ///
    /// **Sentinel contract**: `lastAttempted == -1` is the "fresh playback"
    /// marker set by `stopPlayback` (and the initial value of
    /// `lastAttemptedSavePosition`). On the first tick of new playback,
    /// `abs(seconds - (-1)) >= 1` holds for any `seconds >= 0`, so the
    /// debounce branch reduces to "save proceeds" — desired behavior.
    static func shouldSaveProgress(rate: Float, seconds: Double, lastAttempted: Double) -> Bool {
        guard seconds.isFinite, seconds > 0 else { return false }
        guard rate > 0 else { return false }
        return abs(seconds - lastAttempted) >= 1
    }

    /// Logs codec FourCC + video dimensions for every video track on the
    /// item. Called from item-status KVO once status==.readyToPlay so tracks
    /// are loaded (we pass `automaticallyLoadedAssetKeys: [.tracks]`).
    /// MainActor-isolated because `AVPlayerItemTrack.assetTrack` is a
    /// MainActor property under Swift 6 strict concurrency.
    @MainActor
    private func logVideoFormat(_ item: AVPlayerItem) async {
        let videoTracks = item.tracks.compactMap { $0.assetTrack }.filter { $0.mediaType == .video }
        for track in videoTracks {
            guard let descs = try? await track.load(.formatDescriptions), let desc = descs.first else { continue }
            let fourCC = CMFormatDescriptionGetMediaSubType(desc)
            let bytes: [UInt8] = [
                UInt8((fourCC >> 24) & 0xff),
                UInt8((fourCC >> 16) & 0xff),
                UInt8((fourCC >> 8) & 0xff),
                UInt8(fourCC & 0xff),
            ]
            let codec = String(decoding: bytes, as: UTF8.self)
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            logger.notice("[Format] video codec=\(codec, privacy: .public) dims=\(dims.width)x\(dims.height)")
        }
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
                recordSeek("[Seek] reason=sponsorBlock category=\(segment.category.rawValue) from=\(String(format: "%.2f", currentTime))s to=\(String(format: "%.2f", segment.endTime))s")
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
            recordSeek("[Seek] reason=undoSkip category=\(segment.category.rawValue) to=\(String(format: "%.2f", segment.startTime))s")
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
        freezeWatchdogTask?.cancel()
        freezeWatchdogTask = nil
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
            if let observer = tailObserver {
                player.removeTimeObserver(observer)
                tailObserver = nil
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
            lastTickPosition = -1
            // Match the init-time default: fresh "now" rather than `0`. Otherwise
            // a stop→re-start cycle on the same VM re-introduces the cosmetic
            // 25-year `[TailReplay] sinceLastSeek=...` skew until the next
            // explicit seek records a new timestamp. Helper is a one-line
            // wrapper so the contract is unit-testable without needing to
            // wire a real `AVPlayer` into a VM SUT.
            lastExplicitSeekAt = Self.resetExplicitSeekTimestamp()
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
