import Foundation
import AVFoundation
import OSLog

private nonisolated let logger = Logger(subsystem: "ru.mzhukov.TAClient", category: "CachingResourceLoader")

private let cachingScheme = "itacache"
private let maxCacheResponseSize = 16 * 1024 * 1024  // 16 MB max per cache read
private let maxNetworkResponseSize = 16 * 1024 * 1024 // 16 MB max per network fetch (data(for:) buffers entire response)

// MARK: - Task 11 / B4 — Request dedup constants
//
// When the resource loader gets a cache miss but the preloader is actively
// downloading and its `endOffset` is within `coverSoonWindow` bytes of the
// requested offset, briefly wait for the preloader to catch up rather than
// firing a duplicate network request (which would steal a TCP connection
// from the preloader per the VideoCache architecture notes).
private let coverSoonWindow: Int64 = 8 * 1024 * 1024  // 8 MB
private let graceSleepMs: UInt64 = 200                // 200 ms between retries
private let maxGraceAttempts = 3                       // up to 600 ms total

final class CachingResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    nonisolated let videoId: String
    nonisolated let originalURL: URL
    nonisolated let token: String
    nonisolated let loaderQueue = DispatchQueue(label: "ru.mzhukov.TAClient.resourceLoader", qos: .userInitiated)

    nonisolated private let networkSession: URLSession

    /// Sync cache access — captured once at init so `fillDataRequest` can read
    /// without an `await` on the hot path (AVPlayer byte-range requests).
    nonisolated let store: CacheStore

    /// Async check: is the preloader actively downloading for `videoId`?
    /// Used by the Task 11 (B4) request-dedup grace loop in `fillDataRequest`
    /// to decide whether a cache miss is worth waiting on vs. falling through
    /// to a duplicate network request. Defaults to
    /// `VideoCachePreloader.shared.isPreloading(videoId:)`; injectable for
    /// tests (which exercise `waitForPreloaderData` directly without a live
    /// preloader actor).
    nonisolated let isPreloadingCheck: @Sendable (String) async -> Bool

    /// Sleep helper (ms). Exposed for tests so they can substitute a zero-delay
    /// or accelerated waiter. Defaults to `Task.sleep(for:)`.
    nonisolated let graceSleep: @Sendable (UInt64) async -> Void

    nonisolated let activeTasksLock = NSLock()
    nonisolated(unsafe) var activeTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// Exposed for tests.
    nonisolated func activeTaskCount() -> Int {
        activeTasksLock.lock()
        defer { activeTasksLock.unlock() }
        return activeTasks.count
    }

    init(
        videoId: String,
        originalURL: URL,
        token: String,
        sessionConfiguration: URLSessionConfiguration? = nil,
        store: CacheStore = VideoCachePreloader.shared.store,
        isPreloadingCheck: (@Sendable (String) async -> Bool)? = nil,
        graceSleep: (@Sendable (UInt64) async -> Void)? = nil
    ) {
        self.videoId = videoId
        self.originalURL = originalURL
        self.token = token
        self.store = store
        self.isPreloadingCheck = isPreloadingCheck ?? { id in
            await VideoCachePreloader.shared.isPreloading(videoId: id)
        }
        self.graceSleep = graceSleep ?? { ms in
            try? await Task.sleep(for: .milliseconds(ms))
        }

        let config: URLSessionConfiguration
        if let sessionConfiguration {
            config = sessionConfiguration
        } else {
            config = URLSessionConfiguration.default
            config.httpCookieStorage = nil
            config.urlCache = nil
        }
        self.networkSession = URLSession(configuration: config)

        super.init()
    }

    deinit {
        networkSession.invalidateAndCancel()
    }

    // MARK: - URL Conversion

    static func cachingURL(from url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let originalScheme = components.scheme else { return nil }
        components.scheme = cachingScheme
        components.fragment = originalScheme
        return components.url
    }

    static func originalURL(from url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == cachingScheme else { return nil }
        components.scheme = components.fragment ?? "https"
        components.fragment = nil
        return components.url
    }

    // MARK: - AVAssetResourceLoaderDelegate

    nonisolated func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        let key = ObjectIdentifier(loadingRequest)
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.handleLoadingRequest(loadingRequest, key: key)
        }
        registerTask(task, forKey: key)
        return true
    }

    nonisolated func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        cancelTask(forKey: ObjectIdentifier(loadingRequest))
    }

    /// Cancel a tracked task by key. Exposed so that tests (which cannot
    /// construct `AVAssetResourceLoadingRequest` directly) can exercise
    /// the cancellation path.
    nonisolated func cancelTask(forKey key: ObjectIdentifier) {
        activeTasksLock.lock()
        let task = activeTasks.removeValue(forKey: key)
        activeTasksLock.unlock()
        task?.cancel()
    }

    /// Register a task for tracking. Exposed for tests.
    nonisolated func registerTask(_ task: Task<Void, Never>, forKey key: ObjectIdentifier) {
        activeTasksLock.lock()
        activeTasks[key] = task
        activeTasksLock.unlock()
    }

    /// Silently remove a tracked task without cancelling it (used by the
    /// request handler's `defer` to clear completed entries).
    nonisolated func removeActiveTask(forKey key: ObjectIdentifier) {
        activeTasksLock.lock()
        activeTasks.removeValue(forKey: key)
        activeTasksLock.unlock()
    }

    // MARK: - Request Handling

    private func handleLoadingRequest(_ loadingRequest: AVAssetResourceLoadingRequest, key: ObjectIdentifier) async {
        defer { removeActiveTask(forKey: key) }

        guard !loadingRequest.isCancelled, !Task.isCancelled else { return }

        if let contentRequest = loadingRequest.contentInformationRequest {
            let ok = await fillContentInfo(contentRequest)
            if !ok {
                loadingRequest.finishLoading(with: URLError(.cannotOpenFile))
                return
            }
        }

        guard !loadingRequest.isCancelled, !Task.isCancelled else { return }

        if let dataRequest = loadingRequest.dataRequest {
            let ok = await fillDataRequest(dataRequest)
            if !ok {
                loadingRequest.finishLoading(with: URLError(.cannotOpenFile))
                return
            }
        }

        if !loadingRequest.isCancelled, !Task.isCancelled {
            loadingRequest.finishLoading()
        }
    }

    private func fillContentInfo(_ contentRequest: AVAssetResourceLoadingContentInformationRequest) async -> Bool {
        // Task 4 region-aware lookup: `cacheStatus` returns the `.main` region
        // only and is `nil` for small-file entries that only have `.prefix`.
        // For content-info we only need `totalSize` + `contentType`, both of
        // which are entry-scoped (identical across regions), so fall back to
        // the prefix region when main isn't there.
        let entryStatus = store.cacheStatus(videoId: videoId)
            ?? store.regionStatus(videoId: videoId, region: .prefix)
        if let entryStatus {
            contentRequest.contentLength = entryStatus.totalSize
            contentRequest.contentType = contentTypeUTI(from: entryStatus.contentType)
            contentRequest.isByteRangeAccessSupported = true
            return true
        }

        var request = URLRequest(url: originalURL)
        request.httpMethod = "HEAD"
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await networkSession.data(for: request)
            if handleUnauthorizedIfNeeded(response: response) { return false }
            if let http = response as? HTTPURLResponse {
                // Only populate content-info on a successful response with a
                // known content length. A 302 / 404 / 500, or a 2xx missing
                // the `Content-Length` header, would otherwise set
                // `contentLength` from `expectedContentLength` (which is -1
                // when the header is absent), handing AVPlayer a nonsense
                // asset description.
                guard (200...299).contains(http.statusCode) else {
                    logger.error("HEAD request returned non-success status \(http.statusCode)")
                    return false
                }
                guard http.expectedContentLength > 0 else {
                    logger.error("HEAD response missing Content-Length for \(self.videoId)")
                    return false
                }
                contentRequest.contentLength = http.expectedContentLength
                let mimeType = http.value(forHTTPHeaderField: "Content-Type") ?? "video/mp4"
                contentRequest.contentType = contentTypeUTI(from: mimeType)
                contentRequest.isByteRangeAccessSupported = true
                return true
            }
        } catch {
            logger.error("HEAD request failed: \(error.localizedDescription)")
        }
        return false
    }

    private func fillDataRequest(_ dataRequest: AVAssetResourceLoadingDataRequest) async -> Bool {
        // Loop: read up to 16 MB per iteration (cache first, then network fallback),
        // calling `respond(with:)` each time, until the full requested length is
        // satisfied or the task is cancelled.
        while !Task.isCancelled {
            let offset = dataRequest.currentOffset
            let remaining = dataRequest.requestedLength
                - Int(dataRequest.currentOffset - dataRequest.requestedOffset)
            if remaining <= 0 { return true }

            // Try reading from cache first (sync, NSLock-guarded — no executor hop)
            let cacheLength = min(remaining, maxCacheResponseSize)
            if let cachedData = store.readData(
                videoId: videoId,
                offset: offset,
                length: cacheLength
            ), !cachedData.isEmpty {
                dataRequest.respond(with: cachedData)
                continue
            }

            // Task 11 / B4 — Request dedup: if the preloader is actively
            // downloading and its write head is within `coverSoonWindow` bytes
            // of the requested offset, wait briefly for it to catch up rather
            // than firing a duplicate network request. Network fallback would
            // steal a TCP connection from the preloader per the cache arch
            // notes ("Network fallback ALWAYS competes with preload").
            if let graceData = await waitForPreloaderData(offset: offset, length: cacheLength),
               !graceData.isEmpty {
                dataRequest.respond(with: graceData)
                continue
            }

            // Cache miss: fetch from network (capped — data(for:) buffers entire response in memory)
            let networkLength = min(remaining, maxNetworkResponseSize)
            let ok = await fetchFromNetwork(dataRequest: dataRequest, offset: offset, length: networkLength)
            if !ok { return false }
        }
        return !Task.isCancelled
    }

    /// Task 11 / B4 — Brief wait for the preloader to deliver requested bytes
    /// before the loader falls through to the network. Returns cached bytes on
    /// hit (so the caller can `respond(with:)` and skip the duplicate fetch),
    /// or `nil` when the preloader is inactive / too far from the requested
    /// offset / the grace window is exhausted.
    ///
    /// Gating:
    /// - requires an entry for `videoId` in the store (the preloader's write
    ///   head is the entry's `endOffset`),
    /// - requires `offset >= endOffset` (we only wait for forward progress),
    /// - requires `offset - endOffset < coverSoonWindow`,
    /// - requires the preloader to still be active for `videoId`.
    ///
    /// **Region-aware** (Task 4 of prefix-cache-region plan): an entry may hold
    /// two regions (`.prefix` and `.main`). The "is preloader close to serving
    /// this offset" decision must be made against the region that *would*
    /// contain the requested offset, not the single `.main` status. We pick the
    /// target region by comparing `offset` against each region's
    /// `[startOffset, endOffset)` range and the gap distance to its
    /// `endOffset`:
    ///
    /// 1. Try `.prefix` — if `offset` falls inside or within `coverSoonWindow`
    ///    of its `endOffset` (i.e. forward of the prefix write head), use its
    ///    `endOffset` for the gap math.
    /// 2. Otherwise try `.main` — same check.
    /// 3. If neither region is a candidate, return `nil` (caller falls through
    ///    to network as before).
    ///
    /// This ensures a prefix-region request waits on the prefix preloader task
    /// even when the `.main` write head is far ahead (e.g. resume at byte 470M
    /// with prefix downloading concurrently at byte 5M).
    ///
    /// Exposed `internal` so `CachingResourceLoaderTests` can exercise the
    /// dedup loop directly (AVAssetResourceLoadingDataRequest has no public
    /// initializer, so we can't drive `fillDataRequest` end-to-end from Swift
    /// Testing).
    func waitForPreloaderData(offset: Int64, length: Int) async -> Data? {
        guard let endOffset = relevantEndOffset(forOffset: offset) else { return nil }
        guard offset >= endOffset else { return nil }
        guard offset - endOffset < coverSoonWindow else { return nil }
        guard await isPreloadingCheck(videoId) else { return nil }

        for _ in 0..<maxGraceAttempts {
            await graceSleep(graceSleepMs)
            if Task.isCancelled { return nil }
            if let data = store.readData(videoId: videoId, offset: offset, length: length),
               !data.isEmpty {
                return data
            }
        }
        return nil
    }

    /// Returns the relevant region's `endOffset` to gauge gap distance
    /// against `offset`. Prefix is chosen when `offset` lies before main's
    /// `startOffset` (or main doesn't exist); otherwise main. The actual
    /// distance / `coverSoonWindow` check is the caller's responsibility
    /// (`waitForPreloaderData`).
    ///
    /// Given the prefix/main layout (`prefix` covers `[0, N)`, `main` starts
    /// at `max(N, resumeByte)`), this resolves to:
    /// - `offset < main.startOffset` (or no main): prefix.endOffset
    /// - otherwise: main.endOffset
    /// Returns `nil` only when neither region exists.
    private func relevantEndOffset(forOffset offset: Int64) -> Int64? {
        let prefix = store.regionStatus(videoId: videoId, region: .prefix)
        let main = store.regionStatus(videoId: videoId, region: .main)

        if let prefix {
            // Prefix is the natural target when offset is forward of its
            // write head AND main hasn't yet started covering this offset
            // (offset < main.startOffset, or no main at all). The
            // distance-from-write-head check is performed by the caller.
            let mainStart = main?.startOffset ?? Int64.max
            if offset < mainStart {
                return prefix.endOffset
            }
        }

        if let main {
            return main.endOffset
        }

        return prefix?.endOffset
    }

    private func fetchFromNetwork(
        dataRequest: AVAssetResourceLoadingDataRequest,
        offset: Int64,
        length: Int
    ) async -> Bool {
        var request = URLRequest(url: originalURL)
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        let endByte = offset + Int64(length) - 1
        request.setValue("bytes=\(offset)-\(endByte)", forHTTPHeaderField: "Range")

        do {
            let (data, response) = try await networkSession.data(for: request)
            if handleUnauthorizedIfNeeded(response: response) { return false }
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) || http.statusCode == 206 else {
                logger.error("Network fetch failed: status \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return false
            }
            // Guard: 200/206 with empty body would cause `fillDataRequest`'s
            // while-loop to spin forever (currentOffset never advances). Treat
            // as a fatal response so the outer loop surfaces the failure.
            guard !data.isEmpty else {
                logger.error("Network fetch returned 0 bytes at offset \(offset) — aborting to avoid infinite loop")
                return false
            }
            // Defensive: if a server ignored our Range header and returned the
            // full resource (200 OK with expectedContentLength == totalSize),
            // slicing from `offset` keeps us from handing wrong-offset bytes
            // to AVPlayer via `respond(with:)`. For a well-behaved 206 this is
            // a no-op because `data.count == length`.
            //
            // Two cases:
            //   1. offset > 0: slice bytes starting from `offset` (server
            //      returned full file instead of requested range).
            //   2. offset == 0 but data.count > length: cap to `length` so we
            //      don't hand AVPlayer more bytes than it asked for (which
            //      breaks the `currentOffset` accounting in the while loop).
            let sliced: Data
            if http.statusCode == 200,
               offset > 0,
               data.count > length,
               Int64(data.count) > offset {
                let end = min(data.count, Int(offset) + length)
                sliced = data.subdata(in: Int(offset)..<end)
                logger.warning("Server ignored Range header; sliced \(sliced.count)B from full response at offset \(offset)")
            } else if http.statusCode == 200,
                      offset == 0,
                      data.count > length {
                sliced = data.prefix(length)
                logger.warning("Server ignored Range header; truncated \(data.count)B full response to first \(length)B")
            } else {
                sliced = data
            }
            dataRequest.respond(with: sliced)
            return true
        } catch {
            logger.error("Network fetch error at offset \(offset): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Helpers

    /// Detects HTTP 401/403 responses and posts `.taAuthUnauthorized` so
    /// `AppRouter` can drop the user back to the login screen. Returns `true`
    /// when the response indicated an auth failure (the caller should bail
    /// out). Centralised so both `fillContentInfo` and `fetchFromNetwork`
    /// share one detection path, and so unit tests can exercise the
    /// dispatch logic directly without an `AVAssetResourceLoadingRequest`.
    func handleUnauthorizedIfNeeded(response: URLResponse?) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        if http.statusCode == 401 || http.statusCode == 403 {
            logger.error("Unauthorized for \(self.videoId): \(http.statusCode)")
            // Post with `videoId` as `object` so tests can scope observers
            // to a specific loader instance and avoid cross-test bleed.
            // AppRouter's observer uses `object: nil` and ignores the value.
            NotificationCenter.default.post(name: .taAuthUnauthorized, object: self.videoId)
            return true
        }
        return false
    }

    private func contentTypeUTI(from mimeType: String) -> String {
        switch mimeType.lowercased() {
        case let t where t.contains("mp4"): return "public.mpeg-4"
        case let t where t.contains("webm"): return "org.webmproject.webm"
        case let t where t.contains("matroska"): return "org.matroska.mkv"
        case let t where t.contains("mkv"): return "org.matroska.mkv"
        default: return "public.movie"
        }
    }
}
