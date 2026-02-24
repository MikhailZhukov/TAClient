import Foundation
import OSLog

private let logger = Logger(subsystem: "ru.mzhukov.iTubeArchivist", category: "VideoCache")

actor VideoCache {
    static let shared = VideoCache()

    private static let maxCacheSize = 256_000_000    // 256 MB sliding window
    private static let chunkSize = 512 * 1024        // 512 KB

    struct CacheEntry {
        var data: Data
        var startOffset: Int64            // byte offset where data begins in the file
        var totalSize: Int64
        var contentType: String
        var lastAccess: Date
    }

    private var entries: [String: CacheEntry] = [:]
    private var preloadTasks: [String: Task<Void, Never>] = [:]
    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?

    private init() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.handleMemoryPressure() }
        }
        source.resume()
        memoryPressureSource = source
    }

    // MARK: - Preloading

    func startPreload(videoId: String, url: URL, token: String, startPosition: Double = 0, duration: Double = 0) {
        preloadTasks[videoId]?.cancel()

        let task = Task { [weak self] in
            guard let self else { return }
            await self.downloadVideo(videoId: videoId, url: url, token: token, startPosition: startPosition, duration: duration)
        }
        preloadTasks[videoId] = task
        logger.info("Started preloading \(videoId) from position \(Int(startPosition))s")
    }

    func cancelPreload(videoId: String) {
        preloadTasks[videoId]?.cancel()
        preloadTasks.removeValue(forKey: videoId)
        logger.info("Cancelled preload for \(videoId)")
    }

    // MARK: - Data Access

    func readData(videoId: String, offset: Int64, length: Int) -> Data? {
        guard var entry = entries[videoId] else { return nil }

        let relativeOffset = Int(offset - entry.startOffset)
        guard relativeOffset >= 0 else { return nil }

        let end = min(relativeOffset + length, entry.data.count)
        guard relativeOffset < entry.data.count else { return nil }

        entry.lastAccess = Date()
        entries[videoId] = entry
        return entry.data[relativeOffset..<end]
    }

    /// Trim already-played data from the front of the cache to free memory.
    func trimBefore(videoId: String, offset: Int64) {
        guard var entry = entries[videoId] else { return }

        // Keep a small margin (4MB) before the offset to handle backward seeks for keyframes
        let trimTo = max(0, Int(offset - entry.startOffset) - 4_000_000)
        guard trimTo > 1_000_000 else { return } // only trim if > 1MB to reclaim

        entry.data.removeSubrange(0..<trimTo)
        entry.startOffset += Int64(trimTo)
        entries[videoId] = entry
    }

    func cachedRange(videoId: String) -> (startOffset: Int64, endOffset: Int64)? {
        guard let entry = entries[videoId] else { return nil }
        return (entry.startOffset, entry.startOffset + Int64(entry.data.count))
    }

    func metadata(videoId: String) -> (totalSize: Int64, contentType: String)? {
        guard let entry = entries[videoId] else { return nil }
        return (entry.totalSize, entry.contentType)
    }

    func isPreloading(videoId: String) -> Bool {
        guard let task = preloadTasks[videoId] else { return false }
        return !task.isCancelled
    }

    // MARK: - Download

    private func downloadVideo(videoId: String, url: URL, token: String, startPosition: Double, duration: Double) async {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)

        // Determine byte offset for resuming
        var byteOffset: Int64 = 0
        var knownTotalSize: Int64 = -1

        if startPosition > 0 && duration > 0 {
            var headRequest = URLRequest(url: url)
            headRequest.httpMethod = "HEAD"
            headRequest.setValue("Token \(token)", forHTTPHeaderField: "Authorization")

            if let (_, headResponse) = try? await session.data(for: headRequest),
               let http = headResponse as? HTTPURLResponse {
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
            let (bytes, response) = try await session.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 206 else {
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

            entries[videoId] = CacheEntry(
                data: Data(),
                startOffset: byteOffset,
                totalSize: totalSize,
                contentType: contentType,
                lastAccess: Date()
            )

            var buffer = Data()
            buffer.reserveCapacity(Self.chunkSize)

            for try await byte in bytes {
                if Task.isCancelled { break }

                buffer.append(byte)

                if buffer.count >= Self.chunkSize {
                    entries[videoId]?.data.append(buffer)
                    buffer.removeAll(keepingCapacity: true)

                    // Sliding window: if cache exceeds limit, trim will handle it
                    // (trimBefore is called by the resource loader as playback advances)
                    let cached = entries[videoId]?.data.count ?? 0
                    if cached > Self.maxCacheSize {
                        // If trim hasn't been called yet, pause briefly to let playback catch up
                        try? await Task.sleep(for: .seconds(1))
                    }
                    evictIfNeeded(excluding: videoId)
                }
            }

            if !buffer.isEmpty {
                entries[videoId]?.data.append(buffer)
            }

            let cached = entries[videoId]?.data.count ?? 0
            logger.info("Preload complete for \(videoId): \(cached / 1_000_000)MB cached from offset \(byteOffset)")
        } catch is CancellationError {
            logger.info("Preload cancelled for \(videoId)")
        } catch {
            logger.error("Preload error for \(videoId): \(error.localizedDescription)")
        }

        preloadTasks.removeValue(forKey: videoId)
    }

    // MARK: - Eviction

    private func evictIfNeeded(excluding activeVideoId: String) {
        let totalSize = entries.values.reduce(0) { $0 + $1.data.count }
        guard totalSize > Self.maxCacheSize else { return }

        let sorted = entries
            .filter { $0.key != activeVideoId }
            .sorted { $0.value.lastAccess < $1.value.lastAccess }

        var currentSize = totalSize
        for (key, _) in sorted {
            guard currentSize > Self.maxCacheSize else { break }
            currentSize -= entries[key]?.data.count ?? 0
            entries.removeValue(forKey: key)
            logger.info("Evicted cache for \(key)")
        }
    }

    private func handleMemoryPressure() {
        for (id, task) in preloadTasks {
            task.cancel()
            preloadTasks.removeValue(forKey: id)
        }
        let count = entries.count
        entries.removeAll()
        if count > 0 {
            logger.warning("Memory pressure: evicted all \(count) cache entries and cancelled preloads")
        }
    }
}
