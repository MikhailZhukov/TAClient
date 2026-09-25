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
    /// Throttle scalar for `[AVAccess]` log emissions. AVPlayer posts an
    /// access log entry on every byte-range completion (many per second on
    /// AV1 4K start). The diagnostic value lives in the trend, not every
    /// sample — 30 s between writes keeps the captured log readable.
    /// Touched on the notification queue; lock-guarded for parity with the
    /// other progressQueue-touched scalars.
    @ObservationIgnored
    nonisolated(unsafe) private var lastAVAccessLogAt: CFAbsoluteTime = 0
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
    /// Snapshot of the streaming URL used to build the currently-playing
    /// asset. Captured in `configureAsset` so the 1Hz reseed trigger can pass
    /// the SAME URL to `VideoCachePreloader.reseedMain` that AVPlayer is
    /// currently using — including after an AirPlay swap rebuilds the asset.
    /// Cleared in `stopPlayback`. Same isolation story as the other
    /// progressQueue-touched scalars: read on the time observer's queue,
    /// written from the MainActor `configureAsset` / `stopPlayback` paths,
    /// guarded by `progressStateLock`.
    @ObservationIgnored
    nonisolated(unsafe) private var streamingURL: URL?
    /// Snapshot of the auth token used to build the currently-playing asset.
    /// Captured + cleared on the same paths as `streamingURL`. The app has no
    /// token-refresh flow — tokens only change on logout/login, so a snapshot
    /// taken at asset construction time is valid for the lifetime of the
    /// asset; a stale-token-during-reseed → 401 → existing
    /// `.taAuthUnauthorized` path → router clears Keychain + returns to login.
    @ObservationIgnored
    nonisolated(unsafe) private var authToken: String?
    /// Wallclock time of the most recent `reseedMain` dispatch from the 1Hz
    /// trigger. Paired with `lastReseedTargetByte` by `ReseedTrigger.shouldDebounce`
    /// to suppress duplicate reseeds when the user rapid-scrubs. Intentionally
    /// NOT reset in `stopPlayback` — values are stateless across stops and a
    /// stale 2s debounce window is harmless once playback ends.
    ///
    /// Defaults to `0` deliberately — this is the only `CFAbsoluteTime` field
    /// in the VM where `0` is the correct sentinel. Unlike `lastExplicitSeekAt`
    /// (which feeds a "seconds since" diagnostic via `CFAbsoluteTimeGetCurrent()
    /// - lastSeek`), `lastReseedAt` is consumed exclusively by
    /// `ReseedTrigger.shouldDebounce(now:lastReseedAt:...)` whose only check is
    /// `now - lastReseedAt < debounceInterval`. With `lastReseedAt = 0` the
    /// elapsed value is ~800 million seconds (current CFAbsoluteTime epoch is
    /// 2001-01-01), making the inequality trivially false — the FIRST tick is
    /// never debounced, which is the intended behavior. No 25-year cosmetic
    /// log skew is possible because this field does not feed any diagnostic
    /// log line. See the contrasting `lastExplicitSeekAt =
    /// VideoDetailViewModel.resetExplicitSeekTimestamp()` default above.
    @ObservationIgnored
    nonisolated(unsafe) private var lastReseedAt: CFAbsoluteTime = 0
    /// Target byte of the most recent reseed dispatch, paired with
    /// `lastReseedAt` for debounce. Same lifecycle as `lastReseedAt`.
    @ObservationIgnored
    nonisolated(unsafe) private var lastReseedTargetByte: Int64 = 0
    /// Wallclock time of the most recent `restartPreloadIfNeeded` dispatch
    /// from the 1Hz trigger. Used by `RestartTrigger.shouldRestart(now:
    /// lastRestartAt:...)` to enforce a 15 s cooldown between restart
    /// attempts so an empty-cache window doesn't dispatch a restart on
    /// every observer tick. Same `nonisolated(unsafe)` + `progressStateLock`-
    /// guarded contract as `lastReseedAt`.
    ///
    /// Defaults to `0` deliberately — same reasoning as `lastReseedAt`: the
    /// only consumer is the inequality `(now - lastRestartAt) >= cooldown`
    /// inside `RestartTrigger.shouldRestart`, where `0` produces a
    /// trivially-elapsed (~800 million second) delta, ensuring the FIRST
    /// tick is never cooldown-blocked. No diagnostic log line reads this
    /// scalar, so the CFAbsoluteTime epoch quirk is harmless here.
    /// Intentionally NOT reset in `stopPlayback` — a stale 15 s cooldown
    /// across stops is harmless.
    @ObservationIgnored
    nonisolated(unsafe) private var lastRestartAt: CFAbsoluteTime = 0

    /// Debounce window for `reseedMain` dispatch from the 1Hz trigger.
    /// Suppresses re-fire when the user rapid-scrubs across multiple
    /// destinations within 2s.
    nonisolated private static let reseedDebounceInterval: CFAbsoluteTime = 2.0
    /// Byte-distance tolerance for the reseed debounce — two reseed targets
    /// within 10 MB of each other are treated as "the same target" for
    /// debounce purposes. Large enough to absorb VBR linear-interpolation
    /// drift between observer ticks; small enough that a deliberate second
    /// scrub to a genuinely different region is not suppressed.
    nonisolated private static let reseedTargetSimilarityBytes: Int64 = 10_000_000  // 10 MB

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
    /// `true` when the active `AVURLAsset` streams directly from the server
    /// (AirPlay-active path, AirPlay-swap mid-playback path, OR cachingURL-
    /// conversion-failure fallback path) — i.e. the local `CachingResourceLoader`
    /// is NOT driving byte-range I/O for the current asset.
    ///
    /// Read on the `progressQueue` (background) inside `evaluateReseedDispatch`
    /// to short-circuit reseed dispatch when the cache is bypassed — writing
    /// to `.main` while AVPlayer is on a direct asset wastes bandwidth on bytes
    /// the player will never read. Writes happen on the MainActor in
    /// `configureAsset` / `handleAirPlayBecameActive` / `stopPlayback`.
    ///
    /// `nonisolated(unsafe)` + `progressStateLock`-guarded matches the existing
    /// pattern of `streamingURL`, `authToken`, `lastReseedAt`, and
    /// `lastReseedTargetByte`. All reads/writes MUST be inside
    /// `progressStateLock.withLock { ... }` to avoid TSan-detectable data races
    /// on the MainActor ⇄ progressQueue boundary.
    @ObservationIgnored
    nonisolated(unsafe) private var isUsingDirectAsset = false
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
        configurePlayerItemAppetite(playerItem)
        let avPlayer = AVPlayer(playerItem: playerItem)
        let directAssetForLog = progressStateLock.withLock { self.isUsingDirectAsset }
        logger.notice("[Start] actionAtItemEnd=\(avPlayer.actionAtItemEnd.rawValue) startPosition=\(self.startPosition)s duration=\(video.duration)s isUsingDirectAsset=\(directAssetForLog)")
        logger.info("[Mem] start playback rss=\(MemoryDiagnostics.residentMBString())")

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

    /// Locked write of `streamingURL` + `authToken` (and optionally
    /// `isUsingDirectAsset`). Extracted from `configureAsset` so the snapshot
    /// side-effect is unit-testable in isolation (no AVPlayer / asset
    /// construction required). `internal` visibility — not `private` — so
    /// `@testable import TAClient` can exercise it directly; in production
    /// it is called from `configureAsset` (URL/token only — direct-asset bit
    /// is written separately for compatibility with cachingURL fallback path)
    /// and `handleAirPlayBecameActive` (all three atomically — see Step 0 of
    /// `evaluateReseedDispatch`: the bypass flag MUST transition under the
    /// same lock acquisition as the new URL/token, otherwise a 1Hz observer
    /// tick can land between the snapshot and the flag write and dispatch
    /// `reseedMain` with the direct-asset URL/token).
    ///
    /// Passing `isDirectAsset: nil` leaves `isUsingDirectAsset` untouched —
    /// callers that want to write only the URL/token pair (e.g. `configureAsset`
    /// at the top of the method, before its branch picks the asset shape) use
    /// the default. Callers that need the three-field atomic transition pass
    /// the explicit boolean.
    func snapshotPlaybackContext(url: URL?, token: String?, isDirectAsset: Bool? = nil) {
        progressStateLock.withLock {
            self.streamingURL = url
            self.authToken = token
            if let isDirectAsset {
                self.isUsingDirectAsset = isDirectAsset
            }
        }
    }

    /// Test-only setter for `isUsingDirectAsset`. Lets
    /// `ReseedDispatchEvaluationTests` exercise the Step 0 direct-asset
    /// bypass without having to wire a real `AVPlayer` + `AVURLAsset` into
    /// the SUT. Writes under `progressStateLock` to match the production
    /// contract. `internal` visibility — `@testable import TAClient` is the
    /// only intended consumer.
    func setDirectAssetState(_ value: Bool) {
        progressStateLock.withLock {
            self.isUsingDirectAsset = value
        }
    }

    /// Applies AVPlayer "appetite caps" to a freshly-constructed
    /// `AVPlayerItem` — limits both the peak bit rate AVPlayer will fetch and
    /// the duration of pre-buffered media ahead of the playhead.
    ///
    /// **Why:** real-device test on a high-end iPad measured a ~3.89 GB RSS
    /// spike during the first few seconds of 4K AV1 playback (cache was at
    /// ~256 MB budget but AVPlayer's pipeline ate the rest). Root cause:
    /// AVPlayer's `observedBitrate` mis-measures as multi-Gbps during the
    /// initial HTTPS chunks of a single-rendition stream (no adaptive
    /// ladder), and AVPlayer pre-fetches aggressively in response.
    ///
    /// - `preferredPeakBitRate = 25_000_000` (25 Mbps) — covers 4K AV1's
    ///   typical 12-20 Mbps sustained envelope with headroom for VBR peaks.
    ///   Any value below the bogus-Gbps measurement caps the appetite; 25
    ///   Mbps was chosen empirically to avoid AVPlayer refusing single-
    ///   rendition streams (no ladder to downshift to).
    /// - `preferredForwardBufferDuration = 10` — our `CacheStore` already
    ///   holds up to 256 MB, so AVPlayer duplicating that data into an
    ///   unbounded internal buffer is wasted RAM. 10s is enough headroom
    ///   for stall-free playback while keeping the duplicate buffer bounded.
    ///   (Previously 30s; lowered as part of the appetite caps.)
    ///
    /// Full context + tuning escalation path in
    /// `docs/plans/20260527-fix-memory-pressure-recovery.md` (Task 2).
    ///
    /// `internal` (not `private`) so `AVPlayerItemConfigurationTests` can
    /// call directly via `@testable import TAClient` and pin both values.
    /// `nonisolated` because the operation is pure side-effect on the
    /// passed item; no shared state touched.
    nonisolated func configurePlayerItemAppetite(_ item: AVPlayerItem) {
        item.preferredPeakBitRate = 25_000_000
        item.preferredForwardBufferDuration = 10
    }

    /// Result of `evaluateReseedDispatch` when a reseed should fire — bundles
    /// the byte anchor and the auth context snapshotted under
    /// `progressStateLock`. The caller (the 1Hz time observer closure)
    /// dispatches `VideoCachePreloader.shared.reseedMain` with these values.
    /// `internal` visibility so `@testable import` tests can inspect what the
    /// evaluator decided without having to mock the preloader singleton.
    struct ReseedDispatch: Equatable, Sendable {
        let atByte: Int64
        let url: URL
        let token: String
    }

    /// Decides whether the current observer tick should trigger a reseed and,
    /// if so, returns the dispatch payload (`atByte`, `url`, `token`).
    ///
    /// Side effects when returning `.some`: updates `lastReseedAt` and
    /// `lastReseedTargetByte` under `progressStateLock` to "I'm dispatching
    /// this target now" — so a follow-up tick within the debounce window with
    /// a similar target sees the recent timestamp and short-circuits.
    /// No side effects when returning `nil` (skip reseed for this tick).
    ///
    /// `internal` (not `private`) so `@testable import TAClient` can call
    /// directly with a controlled `now` value and assert the field updates +
    /// dispatch decision in isolation — same pattern as
    /// `snapshotPlaybackContext`. In production this is only ever called from
    /// the 1Hz time observer closure in `registerPlayerObservers`.
    ///
    /// Paused-player scrub semantics: this method does NOT consult AVPlayer's
    /// `timeControlStatus` / `rate`. AVPlayer's periodic time observer fires
    /// once after a discrete seek-while-paused (paused-scrub), so we still
    /// want to reseed in that case — pre-warming the new region for the
    /// resume-play is the intended behavior. The plan's "paused does NOT
    /// block reseed" requirement is satisfied by this absence-of-check.
    nonisolated func evaluateReseedDispatch(
        currentSeconds: Double,
        cachedVideoId: String,
        duration: Double,
        now: CFAbsoluteTime
    ) -> ReseedDispatch? {
        // Step 0: direct-asset bypass (AirPlay / cachingURL-fallback path).
        if checkDirectAssetBypass() { return nil }

        // Step 1: store lookup. Step 2: seconds-space trigger. Step 3: byte
        // mapping for the dispatch target. All three are pure once we have
        // the store snapshot, and they share a return-nil short-circuit.
        guard let targetByte = computeReseedTargetByte(
            currentSeconds: currentSeconds,
            cachedVideoId: cachedVideoId,
            duration: duration
        ) else { return nil }

        // Step 4: locked debounce-and-snapshot commit.
        return commitReseedDispatch(targetByte: targetByte, now: now)
    }

    /// Step 0 of `evaluateReseedDispatch`. Returns `true` when AVPlayer is
    /// reading straight from the server URL (AirPlay, AirPlay-swap, or
    /// `CachingResourceLoader.cachingURL` fallback) — in which case
    /// `reseedMain` would download bytes the player never reads.
    ///
    /// Read under `progressStateLock` to match the `nonisolated(unsafe)`
    /// write contract on `isUsingDirectAsset`: writes happen on the MainActor
    /// (`configureAsset`, `handleAirPlayBecameActive`, `stopPlayback`); this
    /// read happens on `progressQueue` (background).
    nonisolated private func checkDirectAssetBypass() -> Bool {
        progressStateLock.withLock { self.isUsingDirectAsset }
    }

    /// Steps 1–3 of `evaluateReseedDispatch`. Reads the `.main` region from
    /// the store, runs the seconds-space `ReseedTrigger.shouldReseed` gate,
    /// and maps `currentSeconds` → byte anchor via the same
    /// `seconds * avgByterate` formula used elsewhere (`logCacheHealth`, the
    /// `currentByte` discussion in CLAUDE.md). Returns `nil` for any of:
    /// missing entry, videoId mismatch, small-file case, in-region position,
    /// or `duration <= 0`. The preloader's `reseedMain` re-clamps into
    /// `[prefixEnd, totalSize]` so VBR slop on the byte mapping is harmless.
    nonisolated private func computeReseedTargetByte(
        currentSeconds: Double,
        cachedVideoId: String,
        duration: Double
    ) -> Int64? {
        guard let mainStatus = VideoCachePreloader.shared.store.regionStatus(
            videoId: cachedVideoId,
            region: .main
        ) else { return nil }

        guard ReseedTrigger.shouldReseed(
            currentSeconds: currentSeconds,
            mainStartOffset: mainStatus.startOffset,
            mainEndOffset: mainStatus.endOffset,
            totalSize: mainStatus.totalSize,
            duration: duration
        ) else { return nil }

        guard duration > 0 else { return nil }
        let avgByterate = Double(mainStatus.totalSize) / duration
        return Int64(currentSeconds * avgByterate)
    }

    /// Step 4 of `evaluateReseedDispatch`. Performs the locked debounce
    /// check + snapshot read + field update in a single `progressStateLock`
    /// acquisition so the four scalars (`lastReseedAt`,
    /// `lastReseedTargetByte`, `streamingURL`, `authToken`) are read/written
    /// atomically — no chance of a rapid re-tick observing partially-updated
    /// state.
    ///
    /// **Pair-check inside the lock** (not after): the debounce timestamps
    /// must ONLY advance when we are committing to dispatch. If we advanced
    /// them and then bailed because `streamingURL` or `authToken` was nil
    /// (e.g. `stopPlayback` cleared them concurrently), a fresh valid tick
    /// landing at the SAME `targetByte` within `reseedDebounceInterval`
    /// would be incorrectly debounced — silently dropping the reseed
    /// dispatch the user actually needs. Reading the pair inside the lock +
    /// advancing timestamps ONLY when the pair is non-nil guarantees
    /// timestamp updates and dispatch decisions are inseparable.
    nonisolated private func commitReseedDispatch(targetByte: Int64, now: CFAbsoluteTime) -> ReseedDispatch? {
        progressStateLock.withLock { () -> ReseedDispatch? in
            if ReseedTrigger.shouldDebounce(
                now: now,
                lastReseedAt: self.lastReseedAt,
                targetByte: targetByte,
                lastTargetByte: self.lastReseedTargetByte,
                debounceInterval: Self.reseedDebounceInterval,
                similarityBytes: Self.reseedTargetSimilarityBytes
            ) {
                return nil
            }
            // Guard `url != nil && token != nil` BEFORE advancing timestamps.
            // Both are set together in `configureAsset` and cleared together
            // in `stopPlayback`, so in practice they are always both nil or
            // both non-nil. The defensive pair-check guards against a future
            // refactor that diverges them — AND against a `stopPlayback`-
            // cleared snapshot landing here mid-tick.
            guard let url = self.streamingURL, let token = self.authToken else {
                return nil
            }
            self.lastReseedAt = now
            self.lastReseedTargetByte = targetByte
            return ReseedDispatch(atByte: targetByte, url: url, token: token)
        }
    }

    /// Result of `evaluateRestartDispatch` when a restart should fire —
    /// bundles the videoId + auth context + playhead anchor snapshotted
    /// under `progressStateLock`. The caller (the 1Hz time observer closure)
    /// dispatches `VideoCachePreloader.shared.restartPreloadIfNeeded` with
    /// these values fire-and-forget, mirroring the `ReseedDispatch` shape.
    struct RestartDispatch: Equatable, Sendable {
        let videoId: String
        let url: URL
        let token: String
        let startPosition: Double
        let duration: Double
    }

    /// Decides whether the current observer tick should trigger a
    /// preload-restart and, if so, returns the dispatch payload
    /// (`videoId`, `url`, `token`, `startPosition`, `duration`).
    ///
    /// Mirrors `evaluateReseedDispatch`'s testable-seam shape — same
    /// nonisolated `@testable`-callable contract, same pair-check-inside-
    /// lock invariant for the timestamp side-effect, same Step 0
    /// direct-asset bypass.
    ///
    /// Side effect when returning `.some`: updates `lastRestartAt` under
    /// `progressStateLock` to "I'm dispatching now" — so a follow-up tick
    /// within the cooldown window sees the recent timestamp and is
    /// short-circuited by `RestartTrigger.shouldRestart`.
    /// No side effects when returning `nil`.
    ///
    /// `internal` visibility (not `private`) so `RestartDispatchEvaluationTests`
    /// can call directly with a controlled `now` value and assert the field
    /// updates + dispatch decision in isolation — same pattern as
    /// `evaluateReseedDispatch`.
    ///
    /// `startPosition` in the returned dispatch is the `currentSeconds`
    /// argument verbatim — restart is anchored at the current playhead,
    /// NOT byte 0. This is load-bearing for the `.critical` recovery flow
    /// where the cache rebuilds from where the user actually is.
    nonisolated func evaluateRestartDispatch(
        cachedVideoId: String,
        currentSeconds: Double,
        duration: Double,
        now: CFAbsoluteTime
    ) -> RestartDispatch? {
        // Step 0: direct-asset bypass (AirPlay / cachingURL-fallback path).
        // Same rationale as `evaluateReseedDispatch`: spawning a preload
        // restart while AVPlayer streams directly wastes bandwidth on bytes
        // the player never reads.
        if checkDirectAssetBypass() { return nil }

        // Step 1: small-file short-circuit. When `totalSize <= prefixSize`
        // no `.main` region is ever created; `regionStatus(.main)` returns
        // nil forever, and the predicate's `?? 0` fallback would make
        // `mainBytes = 0 < threshold` true on every tick after the cooldown
        // elapses. Without this guard, small files spawn a restart-and-wipe
        // loop every 15 s (the actor's `setEntry` inside `startPreloadWithRetry`
        // wipes whatever prefix bytes had accumulated). The whole file
        // already lives in `.prefix`; there is nothing for a restart to do.
        // See code-review "small-file infinite restart loop" finding.
        let mainStatus = VideoCachePreloader.shared.store.regionStatus(
            videoId: cachedVideoId,
            region: .main
        )
        guard let mainStatus else { return nil }
        let mainBytes: Int64 = mainStatus.endOffset - mainStatus.startOffset

        // Step 2: locked snapshot + pair-check + cooldown predicate + timestamp
        // update — all under a single lock acquisition so the read/check/write
        // is atomic against any concurrent commit. Matches
        // `commitReseedDispatch`'s combined-acquisition contract (see code
        // review "cooldown read-then-write is not atomic" finding). The
        // timestamp only advances when we are committing to dispatch — if it
        // advanced and then we bailed because URL/token was nil, a fresh
        // valid tick within the 15 s cooldown would be incorrectly throttled.
        return progressStateLock.withLock { () -> RestartDispatch? in
            guard RestartTrigger.shouldRestart(
                mainCachedByteCount: mainBytes,
                lastRestartAt: self.lastRestartAt,
                now: now
            ) else { return nil }
            guard let url = self.streamingURL, let token = self.authToken else {
                return nil
            }
            self.lastRestartAt = now
            return RestartDispatch(
                videoId: cachedVideoId,
                url: url,
                token: token,
                startPosition: currentSeconds,
                duration: duration
            )
        }
    }

    /// Builds the `AVURLAsset` according to the active route. Side effects
    /// (setting `isUsingDirectAsset`, retaining the caching loader, snapshotting
    /// the streaming URL + token for the 1Hz reseed trigger) live here so the
    /// caller stays declarative. Snapshotting at the asset-construction
    /// chokepoint — called by both `startAVPlayback` AND
    /// `handleAirPlayBecameActive` — guarantees reseed always dispatches with
    /// the auth context of the currently-playing asset.
    private func configureAsset(url: URL, videoId: String, token: String) -> AVURLAsset {
        // Snapshot URL/token AND isUsingDirectAsset atomically — the fused
        // overload writes all three under one `progressStateLock` acquisition.
        // Passing the explicit boolean here (rather than relying on a
        // post-snapshot assignment) guarantees that a 1Hz observer tick on
        // `progressQueue` cannot observe a torn state where the new URL/token
        // pair is visible but the bypass flag still reflects the previous
        // asset's mode.
        if isAirPlayActive() {
            snapshotPlaybackContext(url: url, token: token, isDirectAsset: true)
            return AVURLAsset(
                url: url,
                options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Token \(token)"]]
            )
        }
        if let cachingURL = CachingResourceLoader.cachingURL(from: url) {
            snapshotPlaybackContext(url: url, token: token, isDirectAsset: false)
            let loader = CachingResourceLoader(videoId: videoId, originalURL: url, token: token)
            let avAsset = AVURLAsset(url: cachingURL)
            avAsset.resourceLoader.setDelegate(loader, queue: loader.loaderQueue)
            self.cachingResourceLoader = loader
            return avAsset
        }
        // cachingURL conversion failed — fall back to direct-streaming asset
        // with the same auth options the AirPlay path uses. Atomically set
        // the direct-asset bit alongside the URL/token snapshot.
        snapshotPlaybackContext(url: url, token: token, isDirectAsset: true)
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
                // Reseed trigger: if playback has jumped far outside the cached
                // `.main` region (large forward or backward scrub), ask the
                // preloader to drop and re-anchor `.main` at the new byte.
                // `evaluateReseedDispatch` is side-effect-only when it returns
                // `nil` (no dispatch); on a `.some`, it has already updated the
                // debounce scalars under the lock and snapshotted url/token —
                // the only thing left for us to do here is fire-and-forget the
                // actor hop to `reseedMain`.
                if let dispatch = self.evaluateReseedDispatch(
                    currentSeconds: seconds,
                    cachedVideoId: cachedVideoId,
                    duration: duration,
                    now: CFAbsoluteTimeGetCurrent()
                ) {
                    Task {
                        await VideoCachePreloader.shared.reseedMain(
                            videoId: cachedVideoId,
                            atByte: dispatch.atByte,
                            url: dispatch.url,
                            token: dispatch.token
                        )
                    }
                }
                // Restart hook: parallel check to the reseed dispatch above.
                // Fires when `.main` has shrunk below 16 MB (post `.critical`
                // emergency-trim or after the entry was dropped entirely)
                // AND the 15 s cooldown has elapsed. The restart is anchored
                // at the current playhead, not byte 0 — the cache rebuilds
                // where the user actually is. `restartPreloadIfNeeded` is
                // idempotent on the preloader side; the VM's `lastRestartAt`
                // cooldown is the single throttle. See
                // `docs/plans/20260527-fix-memory-pressure-recovery.md` Task 6.
                if let restartContext = self.evaluateRestartDispatch(
                    cachedVideoId: cachedVideoId,
                    currentSeconds: seconds,
                    duration: duration,
                    now: CFAbsoluteTimeGetCurrent()
                ) {
                    Task {
                        await VideoCachePreloader.shared.restartPreloadIfNeeded(
                            videoId: restartContext.videoId,
                            url: restartContext.url,
                            token: restartContext.token,
                            startPosition: restartContext.startPosition,
                            duration: restartContext.duration
                        )
                    }
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
        ) { [weak self, weak item] _ in
            guard let self, let item, let event = item.accessLog()?.events.last else { return }
            // 30 s throttle: AVPlayer posts an entry on every byte-range
            // completion (many per second during AV1 4K start). The
            // diagnostic value is in the trend; the firehose just clogs
            // the captured log. Mirrors `lastCacheLogTime`'s pattern.
            let now = CFAbsoluteTimeGetCurrent()
            let should: Bool = self.progressStateLock.withLock {
                if (now - self.lastAVAccessLogAt) >= 30 {
                    self.lastAVAccessLogAt = now
                    return true
                }
                return false
            }
            guard should else { return }
            // bytesTransferred / transferDuration are -1 when AVPlayer hasn't
            // populated them yet for this event; only surface when both are
            // valid so the marker stays parseable.
            let bytes = event.numberOfBytesTransferred
            let xferDuration = event.transferDuration
            let transferField: String
            if bytes >= 0 && xferDuration >= 0 {
                transferField = " bytesTransferred=\(bytes) transferDuration=\(String(format: "%.2f", xferDuration))s"
            } else {
                transferField = ""
            }
            logger.info("[AVAccess] indicatedBitrate=\(Int(event.indicatedBitrate)) observedBitrate=\(Int(event.observedBitrate)) stalls=\(event.numberOfStalls) droppedFrames=\(event.numberOfDroppedVideoFrames) durationWatched=\(String(format: "%.1f", event.durationWatched)) playbackType=\(event.playbackType ?? "?")\(transferField)")
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
        let alreadyDirect = progressStateLock.withLock { self.isUsingDirectAsset }
        guard !alreadyDirect,
              let player, let video,
              let url = URL(string: video.mediaUrl),
              let token = authState.token else { return }

        let currentTime = player.currentTime()

        // Atomically refresh URL/token AND flip the direct-asset bit BEFORE
        // calling `replaceCurrentItem`. The fused snapshot guarantees that a
        // concurrent 1Hz observer tick on `progressQueue` cannot observe
        // partial state — either it sees the OLD asset's context (no reseed
        // races) or the NEW direct-asset context (Step 0 bypass fires). The
        // previous "snapshot URL/token, then several lines later flip the
        // bit" sequence left an ~11-line window where the bypass flag was
        // stale (still `false`) but the URL/token already pointed at the
        // direct-streaming URL — a tick landing in that window would dispatch
        // `reseedMain` with the direct asset's auth context, downloading
        // bytes AVPlayer would never read.
        snapshotPlaybackContext(url: url, token: token, isDirectAsset: true)

        let asset = AVURLAsset(
            url: url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Token \(token)"]]
        )
        let item = AVPlayerItem(asset: asset, automaticallyLoadedAssetKeys: [.tracks, .duration])
        player.replaceCurrentItem(with: item)
        recordSeek("[Seek] reason=airplaySwap to=\(String(format: "%.2f", currentTime.seconds))s")
        player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero)
        cachingResourceLoader = nil

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

        logger.info("[Cache] \(level) pos=\(Int(playbackPosition))s ahead=\(String(format: "%.0f", effectiveAhead))s cached=\(cachePercent)% range=\(status.startOffset)-\(status.endOffset)/\(status.totalSize) rss=\(MemoryDiagnostics.residentMBString())")
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
        // `isUsingDirectAsset = false` happens later inside the
        // `progressStateLock` block alongside the URL/token/timestamp clears
        // — keeps the write contract consistent (every mutation of
        // `isUsingDirectAsset` is lock-guarded so the background-queue read
        // in `evaluateReseedDispatch` cannot race).
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
            // Clear the snapshot taken by `configureAsset` so the 1Hz reseed
            // trigger's nil-guard short-circuits after teardown. Intentionally
            // do NOT reset `lastReseedAt` / `lastReseedTargetByte` — they're
            // stateless across stops and a stale 2s debounce window is
            // harmless once playback ends.
            streamingURL = nil
            authToken = nil
            // Reset the direct-asset bypass flag under the same lock — keeps
            // every mutation of this field consistent with its
            // `nonisolated(unsafe)` + `progressStateLock`-guarded contract.
            isUsingDirectAsset = false
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
