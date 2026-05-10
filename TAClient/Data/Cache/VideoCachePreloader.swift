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

    private func downloadVideo(videoId: String, url: URL, token: String, startPosition: Double, duration: Double) async {
        // NOTE: `preloadTask` lifecycle is owned by the retry-wrapper Task in
        // `startPreloadWithRetry`. It is NOT cleared here — a prior
        // `defer { preloadTask = nil }` at this point would nil the reference
        // to the enclosing retry-wrapper Task *between* retry attempts, making
        // subsequent `cancelPreload` / `isPreloading` checks see a stale nil
        // and allowing orphan retries to write into a different video's entry.

        let config: URLSessionConfiguration = Self.testSessionConfigurationOverride ?? {
            let c = URLSessionConfiguration.default
            c.httpCookieStorage = nil
            c.urlCache = nil  // prevent response caching — we manage our own cache
            return c
        }()

        var byteOffset: Int64 = 0
        var knownTotalSize: Int64 = -1

        if startPosition > 0 && duration > 0 {
            var headRequest = URLRequest(url: url)
            headRequest.httpMethod = "HEAD"
            headRequest.setValue("Token \(token)", forHTTPHeaderField: "Authorization")

            let headSession = URLSession(configuration: config)
            defer { headSession.finishTasksAndInvalidate() }
            if let (_, headResponse) = try? await headSession.data(for: headRequest),
               let http = headResponse as? HTTPURLResponse {
                if http.statusCode == 401 || http.statusCode == 403 {
                    logger.error("Preload HEAD unauthorized for \(videoId): \(http.statusCode)")
                    // Post with `videoId` as `object` so tests can scope
                    // observers by sender and avoid cross-test bleed.
                    NotificationCenter.default.post(name: .taAuthUnauthorized, object: videoId)
                    return
                }
                knownTotalSize = http.expectedContentLength
                if knownTotalSize > 0 {
                    let fraction = startPosition / duration
                    byteOffset = Int64(Double(knownTotalSize) * fraction)
                    logger.info("Preload \(videoId): seeking to byte \(byteOffset) (\(Int(fraction * 100))% of \(knownTotalSize))")
                }
            }
        }

        var request = URLRequest(url: url)
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        if byteOffset > 0 {
            request.setValue("bytes=\(byteOffset)-", forHTTPHeaderField: "Range")
        }

        do {
            let streamer = StreamingSession()
            let (httpResponse, chunks) = try await streamer.stream(request: request, configuration: config)

            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                logger.error("Preload unauthorized for \(videoId): \(httpResponse.statusCode)")
                // Post with `videoId` as `object` so tests can scope
                // observers by sender and avoid cross-test bleed.
                NotificationCenter.default.post(name: .taAuthUnauthorized, object: videoId)
                return
            }

            guard (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 206 else {
                logger.error("Preload failed for \(videoId): bad status")
                return
            }

            let totalSize: Int64
            if httpResponse.statusCode == 206,
               let rangeHeader = httpResponse.value(forHTTPHeaderField: "Content-Range"),
               let slashIndex = rangeHeader.lastIndex(of: "/"),
               let size = Int64(rangeHeader[rangeHeader.index(after: slashIndex)...]) {
                totalSize = size
            } else if knownTotalSize > 0 {
                totalSize = knownTotalSize
            } else {
                totalSize = httpResponse.expectedContentLength
            }

            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "video/mp4"

            store.setEntry(
                videoId: videoId,
                startOffset: byteOffset,
                totalSize: totalSize,
                contentType: contentType
            )

            var buffer = Data()
            buffer.reserveCapacity(CacheStore.chunkSize)

            for try await chunk in chunks {
                if Task.isCancelled { break }

                buffer.append(chunk)

                while buffer.count >= CacheStore.chunkSize {
                    let cacheChunk = Data(buffer.prefix(CacheStore.chunkSize))
                    buffer = Data(buffer.dropFirst(CacheStore.chunkSize))
                    // writeChunk handles auto-trim internally.
                    _ = store.writeChunk(videoId: videoId, chunk: cacheChunk)

                    // Pause download if cache is too far ahead and trim can't help
                    while store.cachedByteCount(videoId: videoId) > CacheStore.pauseThreshold, !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(2))
                        store.trimFront(videoId: videoId)
                    }
                }
            }

            if !buffer.isEmpty {
                _ = store.writeChunk(videoId: videoId, chunk: buffer)
            }

            let cached = store.cachedByteCount(videoId: videoId)
            logger.info("Preload complete for \(videoId): \(cached / 1_000_000)MB cached from offset \(byteOffset)")
        } catch is CancellationError {
            logger.info("Preload cancelled for \(videoId)")
        } catch {
            logger.error("Preload error for \(videoId): \(error.localizedDescription)")
            if store.cachedByteCount(videoId: videoId) == 0 {
                store.clear()
            }
        }
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
        // Skip if cache already covers the requested start position for this video.
        if let status = store.cacheStatus(videoId: videoId), status.endOffset > status.startOffset, duration > 0 {
            let avgByterate = Double(status.totalSize) / duration
            let requestedByte = Int64(startPosition * avgByterate)
            if requestedByte >= status.startOffset && requestedByte < status.endOffset {
                if isPreloading(videoId: videoId) {
                    logger.info("Preload for \(videoId) already active, skipping")
                    return
                }
                let cachedBytes = Int(status.endOffset - status.startOffset)
                logger.info("Cache for \(videoId) already covers position \(Int(startPosition))s (\(cachedBytes / 1_000_000)MB cached), skipping preload")
                return
            }
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
                await self.downloadVideo(videoId: videoId, url: url, token: token, startPosition: startPosition, duration: duration)
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
}
