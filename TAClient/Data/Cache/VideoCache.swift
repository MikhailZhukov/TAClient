import Foundation
import OSLog

private nonisolated let logger = Logger(subsystem: "ru.mzhukov.TAClient", category: "VideoCache")

actor VideoCache {
    static let shared = VideoCache()

    private static let maxCacheSize = 256_000_000    // 256 MB sliding window
    private static let trimThreshold = 282_000_000   // trim when cache exceeds this (~10% over max)
    private static let minTrimSize = 10_000_000      // don't bother trimming less than 10 MB
    private static let pauseThreshold = 384_000_000  // pause download when cache exceeds this (1.5x max)
    private static let behindMargin = 30_000_000     // keep 30 MB behind playback for keyframe/audio refs
    private static let chunkSize = 512 * 1024        // 512 KB

    struct CacheEntry {
        let videoId: String
        var chunks: [Data]                // array of fixed-size chunks (each up to chunkSize)
        var cachedByteCount: Int = 0      // total bytes across all chunks
        var startOffset: Int64            // byte offset where first chunk begins in the file
        var totalSize: Int64
        var contentType: String
    }

    private var entry: CacheEntry?
    private var preloadTask: Task<Void, Never>?
    private var lastPlaybackOffset: Int64 = 0       // updated by ViewModel based on actual playback time
    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?

    private init() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
        memoryPressureSource = source
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.clear() }
        }
        source.resume()
    }

    // MARK: - Preloading

    func startPreload(videoId: String, url: URL, token: String, startPosition: Double = 0, duration: Double = 0) {
        // Skip if cache already covers the requested start position
        if let entry, entry.videoId == videoId, entry.cachedByteCount > 0, duration > 0 {
            let avgByterate = Double(entry.totalSize) / duration
            let requestedByte = Int64(startPosition * avgByterate)
            let cacheEnd = entry.startOffset + Int64(entry.cachedByteCount)
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
        lastPlaybackOffset = 0

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
        guard relativeOffset >= 0, relativeOffset < entry.cachedByteCount else { return nil }

        let end = min(relativeOffset + length, entry.cachedByteCount)
        let bytesNeeded = end - relativeOffset

        var result = Data(capacity: bytesNeeded)
        var remaining = bytesNeeded
        var currentOffset = relativeOffset

        while remaining > 0 {
            let chunkIndex = currentOffset / Self.chunkSize
            let offsetInChunk = currentOffset % Self.chunkSize

            guard chunkIndex < entry.chunks.count else { break }
            let chunk = entry.chunks[chunkIndex]
            guard offsetInChunk < chunk.count else { break }

            let available = min(remaining, chunk.count - offsetInChunk)
            result.append(chunk[offsetInChunk..<(offsetInChunk + available)])

            remaining -= available
            currentOffset += available
        }

        return result.isEmpty ? nil : result
    }

    func cacheStatus(videoId: String) -> (startOffset: Int64, endOffset: Int64, totalSize: Int64, contentType: String)? {
        guard let entry, entry.videoId == videoId else { return nil }
        return (entry.startOffset, entry.startOffset + Int64(entry.cachedByteCount), entry.totalSize, entry.contentType)
    }

    func updatePlaybackPosition(videoId: String, seconds: Double, duration: Double) {
        guard let entry, entry.videoId == videoId, duration > 0 else { return }
        let avgByterate = Double(entry.totalSize) / duration
        lastPlaybackOffset = Int64(seconds * avgByterate)
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

    // MARK: - Trim

    /// Drop complete chunks well behind playback position. O(1) per chunk — no large memmove.
    private func trimFront(videoId: String) {
        guard let entry, entry.videoId == videoId else { return }
        let safeTrimBound = lastPlaybackOffset - Int64(Self.behindMargin)
        let maxTrimBytes = Int(safeTrimBound - entry.startOffset)
        guard maxTrimBytes >= Self.minTrimSize else { return }

        let trimBytes = min(maxTrimBytes, entry.cachedByteCount - Self.maxCacheSize)
        guard trimBytes >= Self.minTrimSize else { return }

        // Remove complete chunks from front
        let chunksToRemove = trimBytes / Self.chunkSize
        guard chunksToRemove > 0 else { return }

        let bytesRemoved = entry.chunks.prefix(chunksToRemove).reduce(0) { $0 + $1.count }
        self.entry?.chunks.removeFirst(chunksToRemove)
        self.entry?.cachedByteCount -= bytesRemoved
        self.entry?.startOffset += Int64(bytesRemoved)
        logger.info("Trimmed \(bytesRemoved / 1_000_000)MB from front of \(videoId)")
    }

    // MARK: - Download

    private func downloadVideo(videoId: String, url: URL, token: String, startPosition: Double, duration: Double) async {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil
        config.urlCache = nil  // prevent response caching — we manage our own cache

        var byteOffset: Int64 = 0
        var knownTotalSize: Int64 = -1

        if startPosition > 0 && duration > 0 {
            var headRequest = URLRequest(url: url)
            headRequest.httpMethod = "HEAD"
            headRequest.setValue("Token \(token)", forHTTPHeaderField: "Authorization")

            let headSession = URLSession(configuration: config)
            if let (_, headResponse) = try? await headSession.data(for: headRequest),
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
            let streamer = StreamingSession()
            let (httpResponse, chunks) = try await streamer.stream(request: request, configuration: config)

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

            entry = CacheEntry(
                videoId: videoId,
                chunks: [],
                cachedByteCount: 0,
                startOffset: byteOffset,
                totalSize: totalSize,
                contentType: contentType
            )

            var buffer = Data()
            buffer.reserveCapacity(Self.chunkSize)

            for try await chunk in chunks {
                if Task.isCancelled { break }

                buffer.append(chunk)

                while buffer.count >= Self.chunkSize {
                    let cacheChunk = Data(buffer.prefix(Self.chunkSize))
                    buffer = Data(buffer.dropFirst(Self.chunkSize))
                    entry?.chunks.append(cacheChunk)
                    entry?.cachedByteCount += cacheChunk.count

                    // Sliding window: trim chunks well behind playback position
                    if let entry, entry.cachedByteCount > Self.trimThreshold {
                        trimFront(videoId: videoId)
                    }

                    // Pause download if cache is too far ahead and trim can't help
                    while let entry, entry.cachedByteCount > Self.pauseThreshold, !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(2))
                        trimFront(videoId: videoId)
                    }
                }
            }

            if !buffer.isEmpty {
                entry?.chunks.append(buffer)
                entry?.cachedByteCount += buffer.count
            }

            let cached = entry?.cachedByteCount ?? 0
            logger.info("Preload complete for \(videoId): \(cached / 1_000_000)MB cached from offset \(byteOffset)")
        } catch is CancellationError {
            logger.info("Preload cancelled for \(videoId)")
        } catch {
            logger.error("Preload error for \(videoId): \(error.localizedDescription)")
            if let entry, entry.cachedByteCount == 0 {
                self.entry = nil
            }
        }

        preloadTask = nil
    }
}
