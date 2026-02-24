import Foundation
import OSLog

private let logger = Logger(subsystem: "ru.mzhukov.iTubeArchivist", category: "VideoCache")

actor VideoCache {
    static let shared = VideoCache()

    private static let maxCacheSize = 256_000_000    // 256 MB sliding window
    private static let trimThreshold = 282_000_000   // trim when cache exceeds this (~10% over max)
    private static let trimTarget = 204_000_000      // trim down to this (~80% of max, ~50 MB freed)
    private static let chunkSize = 512 * 1024        // 512 KB

    struct CacheEntry {
        let videoId: String
        var data: Data
        var startOffset: Int64            // byte offset where data begins in the file
        var totalSize: Int64
        var contentType: String
    }

    private var entry: CacheEntry?
    private var preloadTask: Task<Void, Never>?
    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?

    private init() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.clear() }
        }
        source.resume()
        memoryPressureSource = source
    }

    // MARK: - Preloading

    func startPreload(videoId: String, url: URL, token: String, startPosition: Double = 0, duration: Double = 0) {
        // Skip if cache already covers the requested start position
        if let entry, entry.videoId == videoId, entry.data.count > 0, duration > 0 {
            let avgByterate = Double(entry.totalSize) / duration
            let requestedByte = Int64(startPosition * avgByterate)
            let cacheEnd = entry.startOffset + Int64(entry.data.count)
            if requestedByte >= entry.startOffset && requestedByte < cacheEnd {
                if isPreloading(videoId: videoId) {
                    logger.info("Preload for \(videoId) already active, skipping")
                    return
                }
                logger.info("Cache for \(videoId) already covers position \(Int(startPosition))s, skipping preload")
                return
            }
        }

        // Clear previous video's cache and preload
        preloadTask?.cancel()
        preloadTask = nil
        entry = nil

        let task = Task { [weak self] in
            guard let self else { return }
            await self.downloadVideo(videoId: videoId, url: url, token: token, startPosition: startPosition, duration: duration)
        }
        preloadTask = task
        logger.info("Started preloading \(videoId) from position \(Int(startPosition))s")
    }

    func cancelPreload(videoId: String) {
        guard entry?.videoId == videoId else { return }
        preloadTask?.cancel()
        preloadTask = nil
        logger.info("Cancelled preload for \(videoId)")
    }

    // MARK: - Data Access

    func readData(videoId: String, offset: Int64, length: Int) -> Data? {
        guard let entry, entry.videoId == videoId else { return nil }

        let relativeOffset = Int(offset - entry.startOffset)
        guard relativeOffset >= 0, relativeOffset < entry.data.count else { return nil }

        let end = min(relativeOffset + length, entry.data.count)
        return entry.data[relativeOffset..<end]
    }

    func cachedRange(videoId: String) -> (startOffset: Int64, endOffset: Int64)? {
        guard let entry, entry.videoId == videoId else { return nil }
        return (entry.startOffset, entry.startOffset + Int64(entry.data.count))
    }

    func metadata(videoId: String) -> (totalSize: Int64, contentType: String)? {
        guard let entry, entry.videoId == videoId else { return nil }
        return (entry.totalSize, entry.contentType)
    }

    func isPreloading(videoId: String) -> Bool {
        guard let entry, entry.videoId == videoId, let preloadTask else { return false }
        return !preloadTask.isCancelled
    }

    func clear() {
        preloadTask?.cancel()
        preloadTask = nil
        entry = nil
        logger.info("Cache cleared")
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

            entry = CacheEntry(
                videoId: videoId,
                data: Data(),
                startOffset: byteOffset,
                totalSize: totalSize,
                contentType: contentType
            )

            var buffer = Data()
            buffer.reserveCapacity(Self.chunkSize)

            for try await byte in bytes {
                if Task.isCancelled { break }

                buffer.append(byte)

                if buffer.count >= Self.chunkSize {
                    entry?.data.append(buffer)
                    buffer.removeAll(keepingCapacity: true)

                    // Sliding window: trim front in bulk when well over limit
                    if let cached = entry?.data.count, cached > Self.trimThreshold {
                        let excess = cached - Self.trimTarget
                        entry?.data.removeSubrange(0..<excess)
                        entry?.startOffset += Int64(excess)
                        logger.info("Trimmed \(excess / 1_000_000)MB from front of \(videoId)")
                    }
                }
            }

            if !buffer.isEmpty {
                entry?.data.append(buffer)
            }

            let cached = entry?.data.count ?? 0
            logger.info("Preload complete for \(videoId): \(cached / 1_000_000)MB cached from offset \(byteOffset)")
        } catch is CancellationError {
            logger.info("Preload cancelled for \(videoId)")
        } catch {
            logger.error("Preload error for \(videoId): \(error.localizedDescription)")
        }

        preloadTask = nil
    }
}
