import Foundation
import AVFoundation
import UniformTypeIdentifiers
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

    /// Result of this loader's own HEAD probe, used when the preloader has no
    /// cache entry. Guarded by `contentInfoLock`.
    nonisolated let contentInfoLock = NSLock()
    nonisolated(unsafe) var probedContentInfo: (length: Int64, mimeType: String?)?

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
        let box = LoadingRequestBox(request: loadingRequest)
        // Detached so the async work never hops to the main actor (the
        // module's default isolation). Every touch of the loading request
        // itself goes back through `loaderQueue` — the queue this delegate was
        // registered on — see `onLoaderQueue`.
        let task: Task<Void, Never> = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.handleLoadingRequest(box, key: key)
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

    // MARK: - Loader queue

    /// Runs `work` on `loaderQueue`, the queue passed to
    /// `AVAssetResourceLoader.setDelegate(_:queue:)`. AVFoundation delivers
    /// `shouldWaitForLoadingOfRequestedResource` / `didCancel` on that queue,
    /// and every read of a loading request's state (`isCancelled`,
    /// `currentOffset`) and every `respond(with:)` / `finishLoading` must be
    /// serialized with those callbacks. iOS 27 is strict about this: answering
    /// from another thread (previously the main actor) races `didCancel` and
    /// can leave the asset stuck loading.
    nonisolated private func onLoaderQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            loaderQueue.async {
                continuation.resume(returning: work())
            }
        }
    }

    // MARK: - Request Handling

    nonisolated private func handleLoadingRequest(_ box: LoadingRequestBox, key: ObjectIdentifier) async {
        defer { removeActiveTask(forKey: key) }
        guard !Task.isCancelled else { return }
        let shape = await onLoaderQueue {
            (cancelled: box.request.isCancelled,
             wantsContentInfo: box.request.contentInformationRequest != nil,
             wantsData: box.request.dataRequest != nil)
        }
        guard !shape.cancelled else { return }

        if shape.wantsContentInfo {
            let ok = await fillContentInfo(box)
            if !ok {
                await finish(box, error: URLError(.cannotOpenFile))
                return
            }
        }

        guard !Task.isCancelled else { return }

        if shape.wantsData {
            let ok = await fillDataRequest(box)
            if !ok {
                await finish(box, error: URLError(.cannotOpenFile))
                return
            }
        }

        await finish(box, error: nil)
    }

    /// Finishes the loading request on `loaderQueue`, unless AVFoundation has
    /// already cancelled it (responding to a cancelled request is an error).
    nonisolated private func finish(_ box: LoadingRequestBox, error: Error?) async {
        guard !Task.isCancelled else { return }
        await onLoaderQueue {
            let request = box.request
            guard !request.isCancelled, !request.isFinished else { return }
            if let error {
                request.finishLoading(with: error)
            } else {
                request.finishLoading()
            }
        }
    }

    nonisolated private func fillContentInfo(_ box: LoadingRequestBox) async -> Bool {
        guard let info = await resolveContentInfo() else { return false }
        let contentType = Self.contentTypeUTI(mimeType: info.mimeType, url: originalURL)
        await onLoaderQueue {
            guard let contentRequest = box.request.contentInformationRequest else { return }
            contentRequest.contentLength = info.length
            contentRequest.contentType = contentType
            contentRequest.isByteRangeAccessSupported = true
        }
        return true
    }

    /// Total length + MIME type of the resource. Served from the preloader's
    /// cache entry when present, else from a HEAD request whose result is
    /// remembered so data requests can clamp against it without re-probing.
    nonisolated private func resolveContentInfo() async -> (length: Int64, mimeType: String?)? {
        // Task 4 region-aware lookup: `cacheStatus` returns the `.main` region
        // only and is `nil` for small-file entries that only have `.prefix`.
        // For content-info we only need `totalSize` + `contentType`, both of
        // which are entry-scoped (identical across regions), so fall back to
        // the prefix region when main isn't there.
        if let entryStatus = store.cacheStatus(videoId: videoId)
            ?? store.regionStatus(videoId: videoId, region: .prefix) {
            return (entryStatus.totalSize, entryStatus.contentType)
        }

        contentInfoLock.lock()
        let remembered = probedContentInfo
        contentInfoLock.unlock()
        if let remembered { return remembered }

        var request = URLRequest(url: originalURL)
        request.httpMethod = "HEAD"
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await networkSession.data(for: request)
            if handleUnauthorizedIfNeeded(response: response) { return nil }
            guard let http = response as? HTTPURLResponse else { return nil }
            // Only populate content-info on a successful response with a
            // known content length. A 302 / 404 / 500, or a 2xx missing
            // the `Content-Length` header, would otherwise set
            // `contentLength` from `expectedContentLength` (which is -1
            // when the header is absent), handing AVPlayer a nonsense
            // asset description.
            guard (200...299).contains(http.statusCode) else {
                logger.error("HEAD request returned non-success status \(http.statusCode)")
                return nil
            }
            guard http.expectedContentLength > 0 else {
                logger.error("HEAD response missing Content-Length for \(self.videoId)")
                return nil
            }
            let info = (length: http.expectedContentLength,
                        mimeType: http.value(forHTTPHeaderField: "Content-Type"))
            contentInfoLock.lock()
            probedContentInfo = info
            contentInfoLock.unlock()
            return info
        } catch {
            logger.error("HEAD request failed: \(error.localizedDescription)")
        }
        return nil
    }

    nonisolated private func fillDataRequest(_ box: LoadingRequestBox) async -> Bool {
        let request = await onLoaderQueue { () -> (offset: Int64, length: Int, toEnd: Bool)? in
            guard let dataRequest = box.request.dataRequest else { return nil }
            return (dataRequest.requestedOffset, dataRequest.requestedLength,
                    dataRequest.requestsAllDataToEndOfResource)
        }
        guard let request else { return true }

        // Clamp the request to the resource's real length. AVPlayer on iOS 27
        // issues open-ended `requestsAllDataToEndOfResource` requests (where
        // `requestedLength` is not the amount it wants) and ranges that run
        // past EOF; asking the server for bytes beyond EOF returns 416 and
        // fails the whole load.
        let contentLength = await resolveContentInfo()?.length
        guard let end = Self.requestedEndOffset(
            requestedOffset: request.offset,
            requestedLength: request.length,
            requestsAllDataToEnd: request.toEnd,
            contentLength: contentLength
        ) else {
            logger.error("Cannot serve to-end request without a content length for \(self.videoId)")
            return false
        }

        // Loop: read up to 16 MB per iteration (cache first, then network fallback),
        // calling `respond(with:)` each time, until the clamped range is
        // satisfied or the task is cancelled.
        while !Task.isCancelled {
            guard let offset = await onLoaderQueue({ () -> Int64? in
                box.request.isCancelled ? nil : box.request.dataRequest?.currentOffset
            }) else { return false }
            let remaining = end - offset
            if remaining <= 0 { return true }

            // Try reading from cache first (sync, NSLock-guarded — no executor hop)
            let cacheLength = Int(min(remaining, Int64(maxCacheResponseSize)))
            if let cachedData = store.readData(
                videoId: videoId,
                offset: offset,
                length: cacheLength
            ), !cachedData.isEmpty {
                await respond(box, with: cachedData)
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
                await respond(box, with: graceData)
                continue
            }

            // Cache miss: fetch from network (capped — data(for:) buffers entire response in memory)
            let networkLength = Int(min(remaining, Int64(maxNetworkResponseSize)))
            switch await fetchFromNetwork(offset: offset, length: networkLength) {
            case .data(let data):
                await respond(box, with: data)
            case .endOfResource:
                // The server says there is nothing at `offset` (416). The
                // resource is shorter than we were told; everything that
                // exists has been delivered, so finish instead of failing.
                return true
            case .failed:
                return false
            }
        }
        return !Task.isCancelled
    }

    nonisolated private func respond(_ box: LoadingRequestBox, with data: Data) async {
        await onLoaderQueue {
            guard !box.request.isCancelled else { return }
            box.request.dataRequest?.respond(with: data)
        }
    }

    /// Exclusive end offset a data request should be served up to, or `nil`
    /// when the request wants everything to EOF but the length is unknown.
    ///
    /// - `requestsAllDataToEnd`: the end is the content length;
    ///   `requestedLength` is ignored (AVFoundation documents it as not
    ///   meaningful for such requests).
    /// - Otherwise `requestedOffset + requestedLength`, clamped to the
    ///   content length when known so we never ask the server past EOF.
    nonisolated static func requestedEndOffset(
        requestedOffset: Int64,
        requestedLength: Int,
        requestsAllDataToEnd: Bool,
        contentLength: Int64?
    ) -> Int64? {
        let knownLength = contentLength.flatMap { $0 > 0 ? $0 : nil }
        if requestsAllDataToEnd {
            return knownLength
        }
        let (sum, overflow) = requestedOffset.addingReportingOverflow(Int64(max(requestedLength, 0)))
        let naturalEnd = overflow ? Int64.max : sum
        if let knownLength {
            return min(naturalEnd, knownLength)
        }
        return naturalEnd
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
    nonisolated func waitForPreloaderData(offset: Int64, length: Int) async -> Data? {
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
    nonisolated private func relevantEndOffset(forOffset offset: Int64) -> Int64? {
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

    nonisolated enum NetworkFetchResult {
        case data(Data)
        /// 416 Range Not Satisfiable: nothing exists at the requested offset.
        case endOfResource
        case failed
    }

    nonisolated private func fetchFromNetwork(offset: Int64, length: Int) async -> NetworkFetchResult {
        var request = URLRequest(url: originalURL)
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        let endByte = offset + Int64(length) - 1
        request.setValue("bytes=\(offset)-\(endByte)", forHTTPHeaderField: "Range")

        do {
            let (data, response) = try await networkSession.data(for: request)
            if handleUnauthorizedIfNeeded(response: response) { return .failed }
            guard let http = response as? HTTPURLResponse else {
                logger.error("Network fetch failed: non-HTTP response")
                return .failed
            }
            if http.statusCode == 416 {
                logger.warning("Network fetch at offset \(offset) is past EOF (416); finishing request")
                return .endOfResource
            }
            guard (200...299).contains(http.statusCode) else {
                logger.error("Network fetch failed: status \(http.statusCode)")
                return .failed
            }
            // Guard: 200/206 with empty body would cause `fillDataRequest`'s
            // while-loop to spin forever (currentOffset never advances). Treat
            // as a fatal response so the outer loop surfaces the failure.
            guard !data.isEmpty else {
                logger.error("Network fetch returned 0 bytes at offset \(offset) — aborting to avoid infinite loop")
                return .failed
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
            return .data(sliced)
        } catch {
            logger.error("Network fetch error at offset \(offset): \(error.localizedDescription)")
            return .failed
        }
    }

    // MARK: - Helpers

    /// Detects HTTP 401/403 responses and posts `.taAuthUnauthorized` so
    /// `AppRouter` can drop the user back to the login screen. Returns `true`
    /// when the response indicated an auth failure (the caller should bail
    /// out). Centralised so both `fillContentInfo` and `fetchFromNetwork`
    /// share one detection path, and so unit tests can exercise the
    /// dispatch logic directly without an `AVAssetResourceLoadingRequest`.
    nonisolated func handleUnauthorizedIfNeeded(response: URLResponse?) -> Bool {
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

    /// UTI for `contentInformationRequest.contentType`.
    ///
    /// iOS 27's AVFoundation no longer accepts the abstract `public.movie`
    /// as a container type, so this must name a concrete container. Order:
    /// 1. the server's MIME type, when it maps to an audiovisual UTType
    ///    (parameters like `; charset=` are ignored);
    /// 2. the URL's file extension (TA serves `…/<id>.mp4`), covering servers
    ///    that answer `application/octet-stream` or omit `Content-Type`;
    /// 3. `public.mpeg-4`, the container Tube Archivist writes and the only
    ///    one the AVPlayer path handles (VP8/VP9 go through VLC).
    nonisolated static func contentTypeUTI(mimeType: String?, url: URL) -> String {
        if let mimeType {
            let essence = mimeType
                .split(separator: ";", maxSplits: 1)
                .first
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            if let type = UTType(mimeType: essence), type.conforms(to: .audiovisualContent) {
                return type.identifier
            }
            if essence.contains("webm") { return "org.webmproject.webm" }
            if essence.contains("matroska") || essence.contains("mkv") { return "org.matroska.mkv" }
        }
        let ext = url.pathExtension
        if !ext.isEmpty,
           let type = UTType(filenameExtension: ext),
           type.conforms(to: .audiovisualContent) {
            return type.identifier
        }
        return UTType.mpeg4Movie.identifier
    }
}

/// Carries a non-`Sendable` loading request into the detached handler task.
/// Safe because the handler only touches the request inside
/// `CachingResourceLoader.onLoaderQueue`, i.e. serialized on the loader's
/// delegate queue.
nonisolated struct LoadingRequestBox: @unchecked Sendable {
    let request: AVAssetResourceLoadingRequest
}

