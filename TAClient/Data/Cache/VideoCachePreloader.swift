import Foundation
import OSLog

private nonisolated let logger = Logger(subsystem: "ru.mzhukov.TAClient", category: "VideoCachePreloader")

/// Actor wrapper around the synchronous `CacheStore`. Owns the in-flight
/// `preloadTask` and memory-pressure subscription. All cache state lives in
/// `store` so that non-actor code paths (e.g. `CachingResourceLoader`'s hot
/// read path) can access it without an executor hop.
///
/// Renamed from `VideoCache` in Task 10 (C1b). The loader and VM now read
/// `store` directly (sync, NSLock-guarded); this actor is strictly a
/// download orchestrator that owns lifecycle of the in-flight HTTP task.
actor VideoCachePreloader {
    static let shared = VideoCachePreloader()

    /// Synchronous storage — exposed to the actor and to the
    /// `CachingResourceLoader`. All mutable state lives behind its `NSLock`.
    nonisolated let store = CacheStore()

    private var preloadTask: Task<Void, Never>?
    /// Monotonic generation for the currently-stored `preloadTask`. The
    /// retry-wrapper Task captures its generation on spawn and clears
    /// `preloadTask` on exit **only** if the stored generation still matches
    /// — preventing a completing orphan from dropping a newer live preload.
    private var preloadGeneration: Int = 0
    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?

    /// Test hook: when non-nil, replaces the internal `URLSessionConfiguration.default`
    /// used by `downloadVideo`. Allows `MockURLProtocol` to intercept preload
    /// requests for unit tests covering auth-failure dispatch etc.
    ///
    /// Production code **MUST** leave this nil — it's read once on every
    /// `downloadVideo` entry. Setting it at runtime would route all future
    /// preloads through the test mock's URLProtocol and break real playback.
    /// The `nonisolated(unsafe)` marker is a Swift 6 concurrency opt-out
    /// acknowledged here because test setup/teardown runs serially on the
    /// MainActor — production reads from the preloader actor, but production
    /// never writes. Not gated with `#if DEBUG` because `@testable import`
    /// already restricts visibility to test-linked builds.
    nonisolated(unsafe) static var testSessionConfigurationOverride: URLSessionConfiguration?

    private init() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
        memoryPressureSource = source
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            self.handleMemoryPressure(event: event)
        }
        source.resume()
    }

    /// Memory-pressure dispatch. Split from the raw handler so unit tests can
    /// drive the same logic path without synthesising a real DispatchSource
    /// pressure event (there is no public API to trigger one).
    ///
    /// - `.critical`: drop everything, cancel any in-flight preload — the
    ///   system is about to terminate us and there's no time to be surgical.
    /// - `.warning` (anything else): trim the cache down to half of
    ///   `maxCacheSize`, keeping recently-played bytes. Preload keeps
    ///   running; `writeChunk` will re-trim if we overshoot again.
    nonisolated func handleMemoryPressure(event: DispatchSource.MemoryPressureEvent) {
        if event.contains(.critical) {
            store.clear()
            Task { await self.invalidatePreload() }
        } else {
            // .warning (or any non-critical signalled state)
            guard let videoId = store.currentVideoId() else { return }
            let targetSize = CacheStore.maxCacheSize / 2
            let removed = store.emergencyTrim(videoId: videoId, targetSize: targetSize)
            if removed > 0 {
                logger.info("Memory warning: emergency-trimmed \(removed / 1_000_000)MB (target \(targetSize / 1_000_000)MB)")
            }
        }
    }

    /// Cancel any in-flight preload task. Called after the store is cleared
    /// under memory pressure so we don't keep downloading into a nil entry.
    private func invalidatePreload() {
        preloadTask?.cancel()
        preloadTask = nil
    }

    // MARK: - Preloading

    func cancelPreload(videoId: String) {
        guard store.currentVideoId() == videoId else { return }
        preloadTask?.cancel()
        preloadTask = nil
        logger.info("Cancelled preload for \(videoId)")
    }

    // MARK: - Data Access (test-only scaffolding)
    //
    // Production code reads `store.*` directly (sync, NSLock-guarded) — the
    // actor hop is unnecessary on the hot paths in `CachingResourceLoader`
    // and `VideoDetailViewModel`. These async delegates exist ONLY so that
    // `VideoCachePreloaderTests` can continue to exercise the end-to-end
    // preloader → store path through the actor. Do not call from production;
    // use `VideoCachePreloader.shared.store` instead.

    func readData(videoId: String, offset: Int64, length: Int) -> Data? {
        store.readData(videoId: videoId, offset: offset, length: length)
    }

    func cacheStatus(videoId: String) -> (startOffset: Int64, endOffset: Int64, totalSize: Int64, contentType: String)? {
        store.cacheStatus(videoId: videoId)
    }

    func updatePlaybackPosition(videoId: String, seconds: Double, duration: Double) {
        store.updatePlaybackPosition(videoId: videoId, seconds: seconds, duration: duration)
    }

    func isPreloading(videoId: String) -> Bool {
        guard store.currentVideoId() == videoId, let preloadTask else { return false }
        return !preloadTask.isCancelled
    }

    func clear() {
        preloadTask?.cancel()
        preloadTask = nil
        store.clear()
    }

    // MARK: - Download

    /// Build the URLSession configuration used by the preloader's GET and HEAD
    /// requests. Honors the `testSessionConfigurationOverride` test hook so
    /// `MockURLProtocol` can intercept network traffic; production code paths
    /// build a fresh `URLSessionConfiguration.default` with cookie storage and
    /// response caching disabled (we manage our own cache).
    private func makeDownloadConfig() -> URLSessionConfiguration {
        Self.testSessionConfigurationOverride ?? {
            let c = URLSessionConfiguration.default
            c.httpCookieStorage = nil
            c.urlCache = nil
            return c
        }()
    }

    /// Perform a HEAD probe to discover `totalSize` and `contentType`. Returns
    /// `nil` if the probe is unauthorized (401/403; notification already
    /// posted) or fails for any reason — callers should treat that as an
    /// abort signal for the entire preload.
    private func probeTotalSize(videoId: String, url: URL, token: String, config: URLSessionConfiguration) async -> (totalSize: Int64, contentType: String)? {
        var headRequest = URLRequest(url: url)
        headRequest.httpMethod = "HEAD"
        headRequest.setValue("Token \(token)", forHTTPHeaderField: "Authorization")

        let headSession = URLSession(configuration: config)
        defer { headSession.finishTasksAndInvalidate() }

        guard
            let (_, headResponse) = try? await headSession.data(for: headRequest),
            let http = headResponse as? HTTPURLResponse
        else {
            return nil
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            logger.error("Preload HEAD unauthorized for \(videoId): \(http.statusCode)")
            // Post with `videoId` as `object` so tests can scope
            // observers by sender and avoid cross-test bleed.
            NotificationCenter.default.post(name: .taAuthUnauthorized, object: videoId)
            return nil
        }
        guard (200...299).contains(http.statusCode) else {
            logger.error("Preload HEAD failed for \(videoId): status \(http.statusCode)")
            return nil
        }
        let totalSize = http.expectedContentLength
        guard totalSize > 0 else { return nil }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "video/mp4"
        return (totalSize, contentType)
    }

    /// Download a byte range and stream it into the named region of the
    /// `videoId` entry. Used twice per preload — once for the prefix region
    /// (`0..<prefixSize`) and once for the main region
    /// (`mainStartByte..<totalSize`). Each call is independent: a failure or
    /// auth error in one region must not affect the other (the caller awaits
    /// both via `try?` so a thrown error here does not cancel the sibling
    /// task).
    ///
    /// On `Task.isCancelled` the loop exits cleanly without throwing
    /// `CancellationError` — the parent `preloadTask` propagates cancellation
    /// via structured concurrency. On 401/403 we post `.taAuthUnauthorized`
    /// (with `videoId` as `object`) and exit without throwing. On non-2xx
    /// statuses we log and exit. Throws only when `StreamingSession.stream`
    /// or the chunk iterator throws (i.e. transport errors), which lets the
    /// retry wrapper in `startPreloadWithRetry` decide whether to retry —
    /// but with the parallel structure, retry currently re-runs both tasks.
    private func downloadRange(
        videoId: String,
        url: URL,
        token: String,
        range: Range<Int64>,
        into region: CacheStore.RegionID,
        config: URLSessionConfiguration
    ) async throws {
        guard range.lowerBound < range.upperBound else { return }

        var request = URLRequest(url: url)
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        // Inclusive end byte for HTTP `Range:` header (RFC 7233).
        let endByte = range.upperBound - 1
        request.setValue("bytes=\(range.lowerBound)-\(endByte)", forHTTPHeaderField: "Range")

        let streamer = StreamingSession()
        let (httpResponse, chunks) = try await streamer.stream(request: request, configuration: config)

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            logger.error("Preload (\(region.name)) unauthorized for \(videoId): \(httpResponse.statusCode)")
            NotificationCenter.default.post(name: .taAuthUnauthorized, object: videoId)
            return
        }

        guard (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 206 else {
            logger.error("Preload (\(region.name)) failed for \(videoId): bad status \(httpResponse.statusCode)")
            return
        }

        var buffer = Data()
        buffer.reserveCapacity(CacheStore.chunkSize)

        do {
            for try await chunk in chunks {
                if Task.isCancelled { return }

                buffer.append(chunk)

                while buffer.count >= CacheStore.chunkSize {
                    let cacheChunk = Data(buffer.prefix(CacheStore.chunkSize))
                    buffer = Data(buffer.dropFirst(CacheStore.chunkSize))
                    // writeChunk handles auto-trim of `.main` internally; for
                    // `.prefix` it appends without trimming (prefix is pinned).
                    _ = store.writeChunk(videoId: videoId, toRegion: region, chunk: cacheChunk)

                    // Per-region pause gate. Only the `.main` task observes
                    // the pause threshold — it's the only region that can
                    // actually exceed it (prefix is bounded by
                    // `maxPrefixSize = 50 MB` ≪ `pauseThreshold = 384 MB` by
                    // construction). If we instead summed both regions, a
                    // main task that filled past pauseThreshold while
                    // playback was still at byte 0 (user hasn't pressed play
                    // → `lastPlaybackOffset == 0` → `trimFront` returns 0)
                    // would deadlock the prefix task in this Task.sleep loop
                    // forever, since prefix has no `trimFront` lever to pull.
                    if region == .main {
                        while store.cachedByteCount(videoId: videoId) > CacheStore.pauseThreshold, !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(2))
                            store.trimFront(videoId: videoId)
                        }
                    }
                }
            }
        } catch is CancellationError {
            logger.info("Preload (\(region.name)) cancelled for \(videoId)")
            return
        }

        if !buffer.isEmpty {
            _ = store.writeChunk(videoId: videoId, toRegion: region, chunk: buffer)
        }
    }

    /// Orchestrate the full preload for `videoId`: HEAD probe to discover
    /// `totalSize`, seed both regions via `store.setEntry`, then launch the
    /// prefix and main downloads as parallel `async let` tasks.
    ///
    /// Cancellation propagates through structured concurrency — when the
    /// enclosing `preloadTask` is cancelled, both inner `async let` tasks
    /// observe `Task.isCancelled` and exit. Per-task failures (e.g. main
    /// returns 503) do not affect the sibling task because the caller awaits
    /// each with `try?`.
    private func downloadVideo(videoId: String, url: URL, token: String, startPosition: Double, duration: Double, generation: Int) async {
        // NOTE: `preloadTask` lifecycle is owned by the retry-wrapper Task in
        // `startPreloadWithRetry`. It is NOT cleared here — a prior
        // `defer { preloadTask = nil }` at this point would nil the reference
        // to the enclosing retry-wrapper Task *between* retry attempts, making
        // subsequent `cancelPreload` / `isPreloading` checks see a stale nil
        // and allowing orphan retries to write into a different video's entry.

        let config = makeDownloadConfig()

        // Always probe to learn `totalSize`; we need it to compute the prefix
        // size and (when resuming) the main region's start byte. The probe is
        // unconditional now — previously it was gated on `startPosition > 0`,
        // but with parallel prefix+main downloads we always need the size to
        // pick the prefix/main boundary.
        guard let probe = await probeTotalSize(videoId: videoId, url: url, token: token, config: config) else {
            // Either an auth failure (notification already posted) or a HEAD
            // failure — either way, abort the preload cleanly.
            return
        }

        let totalSize = probe.totalSize
        let contentType = probe.contentType
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)

        let rawResumeByte: Int64
        if startPosition > 0, duration > 0 {
            let fraction = startPosition / duration
            rawResumeByte = Int64(Double(totalSize) * fraction)
        } else {
            rawResumeByte = 0
        }
        // Clamp into the file's byte range. Without this clamp, a corrupt
        // saved progress, a re-encoded video that shrunk under us, or simple
        // rounding past duration would push `resumeByte` past `totalSize` and
        // make the later `mainStartByte..<totalSize` range construction trap
        // (Swift Range requires `lowerBound <= upperBound`). `CacheStore.setEntry`
        // applies the same clamp internally; we apply it here so the range
        // expression below is provably safe.
        let resumeByte = min(max(rawResumeByte, 0), totalSize)
        let mainStartByte = max(prefixSize, resumeByte)

        store.setEntry(
            videoId: videoId,
            totalSize: totalSize,
            contentType: contentType,
            resumeByte: resumeByte
        )

        logger.info("Preload \(videoId): totalSize=\(totalSize / 1_000_000)MB, prefixSize=\(prefixSize / 1_000_000)MB, mainStart=\(mainStartByte / 1_000_000)MB (resume=\(resumeByte / 1_000_000)MB)")

        // Parallel prefix + main downloads. Each is independently retried at
        // the transport level by `StreamingSession`; per-task auth failure or
        // 5xx errors post the notification (auth) or log + exit (other) but
        // do not propagate to the sibling task.
        async let prefixResult: Void = downloadRange(
            videoId: videoId,
            url: url,
            token: token,
            range: 0..<prefixSize,
            into: .prefix,
            config: config
        )
        // Skip main when the file fits in the prefix (`totalSize <= prefixSize`)
        // OR when the resume position lands at/past EOF (`mainStartByte >=
        // totalSize`). Both produce degenerate empty ranges that we never
        // want to hand to `downloadRange`.
        let shouldDownloadMain = totalSize > prefixSize && mainStartByte < totalSize
        async let mainResult: Void? = shouldDownloadMain
            ? downloadRange(
                videoId: videoId,
                url: url,
                token: token,
                range: mainStartByte..<totalSize,
                into: .main,
                config: config
            )
            : nil

        // Independent failure: prefix or main can throw without affecting the
        // other. `try?` swallows per-task errors; we log them via the
        // downloadRange logger calls. `await` here keeps the structured-
        // concurrency cancellation propagation intact.
        do {
            try await prefixResult
        } catch is CancellationError {
            logger.info("Prefix preload cancelled for \(videoId)")
        } catch {
            logger.error("Prefix preload error for \(videoId): \(error.localizedDescription)")
        }
        do {
            _ = try await mainResult
        } catch is CancellationError {
            logger.info("Main preload cancelled for \(videoId)")
        } catch {
            logger.error("Main preload error for \(videoId): \(error.localizedDescription)")
        }

        // Generation guard: only clear when this `downloadVideo` invocation
        // is still the "current" preload for the store. If a newer
        // `startPreloadWithRetry` for the same `videoId` has already
        // cancelled us and seeded a fresh entry, `generation` will no longer
        // match `preloadGeneration` and clearing would wipe the new task's
        // seeded entry. The store's `currentVideoId()` check isn't enough on
        // its own — same videoId can be re-seeded under a fresh generation
        // before we get here.
        if generation == preloadGeneration,
           store.cachedByteCount(videoId: videoId) == 0,
           store.currentVideoId() == videoId {
            // Nothing landed in either region (e.g. both transports failed)
            // — clear the entry so the next retry attempt restarts fresh.
            store.clear()
        }

        let cached = store.cachedByteCount(videoId: videoId)
        logger.info("Preload complete for \(videoId): \(cached / 1_000_000)MB cached (prefix=\(prefixSize / 1_000_000)MB, mainStart=\(mainStartByte / 1_000_000)MB)")

        // `preloadTask = nil` is handled by the retry-wrapper Task in
        // `startPreloadWithRetry` after the retry loop exits — see the note
        // at the top of this function.
    }

    /// Retry wrapper: retries transient network errors with exponential backoff.
    ///
    /// Skips the new preload if the cache already covers the requested start
    /// position for this `videoId` (migrated from the removed `startPreload`
    /// fast-path). Otherwise cancels any in-flight preload, clears the store,
    /// and kicks off a fresh download loop with retry on transient errors.
    func startPreloadWithRetry(videoId: String, url: URL, token: String, startPosition: Double = 0, duration: Double = 0, maxRetries: Int = 2) {
        if isCacheSufficient(videoId: videoId, startPosition: startPosition, duration: duration) {
            return
        }

        // Cancel any in-flight preload; clear only if it belongs to a different video.
        preloadTask?.cancel()
        preloadTask = nil
        if store.currentVideoId() != videoId {
            store.clear()
        }

        preloadGeneration &+= 1
        let generation = preloadGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            for attempt in 0...maxRetries {
                if Task.isCancelled { break }
                if attempt > 0 {
                    let delay = Double(1 << (attempt - 1)) // 1s, 2s
                    logger.info("Retry \(attempt)/\(maxRetries) for \(videoId) in \(Int(delay))s")
                    try? await Task.sleep(for: .seconds(delay))
                    if Task.isCancelled { break }
                }
                await self.downloadVideo(videoId: videoId, url: url, token: token, startPosition: startPosition, duration: duration, generation: generation)
                // If we got data or task was cancelled, don't retry
                let cached = self.store.cachedByteCount(videoId: videoId)
                if cached > 0 { break }
                if Task.isCancelled { break }
            }
            // Generation-guarded clear: only nil `preloadTask` if no newer
            // `startPreloadWithRetry` has bumped the generation. Otherwise
            // the live preload's reference would be dropped, breaking
            // `cancelPreload` / `isPreloading`.
            await self.finalizePreloadIfCurrent(generation: generation)
        }
        preloadTask = task
    }

    /// Compare-and-clear `preloadTask` against the generation recorded when
    /// the retry wrapper Task was spawned. Runs on the actor so the check
    /// and the subsequent assignment are serialized with
    /// `startPreloadWithRetry` and `cancelPreload`.
    private func finalizePreloadIfCurrent(generation: Int) {
        guard generation == preloadGeneration else { return }
        preloadTask = nil
    }

    /// Returns `true` when the cache already covers what playback needs for
    /// `videoId` at `startPosition` (seconds): BOTH `.prefix` and `.main`
    /// regions populated, AND `.main` covers the byte offset for the
    /// requested start position. Used by `startPreloadWithRetry` to skip
    /// redundant preload on re-open.
    ///
    /// The fast-path must be region-aware: a prior `.critical` memory
    /// pressure event may have dropped the `.prefix` region, and re-using
    /// the cache without re-downloading prefix would silently re-introduce
    /// the scrub-after-resume freeze (no cached moov atom). Require BOTH
    /// `.prefix` populated AND `.main` covering the requested byte before
    /// we declare the cache "good enough" to skip.
    private func isCacheSufficient(videoId: String, startPosition: Double, duration: Double) -> Bool {
        guard duration > 0,
              let mainStatus = store.regionStatus(videoId: videoId, region: .main),
              mainStatus.endOffset > mainStatus.startOffset,
              let prefixStatus = store.regionStatus(videoId: videoId, region: .prefix),
              prefixStatus.endOffset > 0
        else {
            return false
        }
        let avgByterate = Double(mainStatus.totalSize) / duration
        let requestedByte = Int64(startPosition * avgByterate)
        guard requestedByte >= mainStatus.startOffset, requestedByte < mainStatus.endOffset else {
            return false
        }
        if isPreloading(videoId: videoId) {
            logger.info("Preload for \(videoId) already active, skipping")
            return true
        }
        let cachedBytes = Int(mainStatus.endOffset - mainStatus.startOffset)
        logger.info("Cache for \(videoId) already covers position \(Int(startPosition))s (\(cachedBytes / 1_000_000)MB main + \(prefixStatus.endOffset / 1_000_000)MB prefix), skipping preload")
        return true
    }
}
