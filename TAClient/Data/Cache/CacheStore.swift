import Foundation
import OSLog

private nonisolated let logger = Logger(subsystem: "ru.mzhukov.TAClient", category: "CacheStore")

/// Thread-safe synchronous storage layer underlying `VideoCachePreloader`.
///
/// Extracted from the original `VideoCache` actor (Task 9 / C1a) so the
/// `CachingResourceLoader` hot-read path can hit cache without an actor
/// executor hop. Task 10 / C1b switched loader + VM to use this type
/// directly; the preloader (renamed `VideoCachePreloader`) still delegates
/// through here. All mutable
/// state (`entry`, `lastPlaybackOffset`) is protected by a single `NSLock`
/// held only for the duration of the critical section. No async, no actor.
///
/// Public API is deliberately synchronous — callers on any queue can invoke
/// these methods without `await`. All members are `nonisolated` so the class
/// can be used from any actor context (the project default isolation is
/// MainActor, but this class is intentionally concurrency-neutral).
nonisolated final class CacheStore: @unchecked Sendable {

    // MARK: - Tuning

    static let maxCacheSize = 256_000_000    // 256 MB sliding window
    static let trimThreshold = 282_000_000   // trim when cache exceeds this (~10% over max)
    static let minTrimSize = 10_000_000      // don't bother trimming less than 10 MB
    static let pauseThreshold = 384_000_000  // pause download when cache exceeds this (1.5x max)
    static let behindMargin = 30_000_000     // keep 30 MB behind playback for keyframe/audio refs
    static let chunkSize = 512 * 1024        // 512 KB

    // MARK: - CacheEntry

    struct CacheEntry {
        let videoId: String
        var chunks: [Data]                // array of fixed-size chunks (each up to chunkSize)
        var cachedByteCount: Int = 0      // total bytes across all chunks
        var startOffset: Int64            // byte offset where first chunk begins in the file
        var totalSize: Int64
        var contentType: String
    }

    // MARK: - State (protected by `lock`)

    private let lock = NSLock()
    private var entry: CacheEntry?
    private var lastPlaybackOffset: Int64 = 0

    init() {}

    // MARK: - Reads

    func readData(videoId: String, offset: Int64, length: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry, entry.videoId == videoId else { return nil }

        let relativeOffset = Int(offset - entry.startOffset)
        guard relativeOffset >= 0, relativeOffset < entry.cachedByteCount else { return nil }

        let end = min(relativeOffset + length, entry.cachedByteCount)
        let bytesNeeded = end - relativeOffset
        guard bytesNeeded > 0 else { return nil }

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
        lock.lock()
        defer { lock.unlock() }
        guard let entry, entry.videoId == videoId else { return nil }
        return (entry.startOffset, entry.startOffset + Int64(entry.cachedByteCount), entry.totalSize, entry.contentType)
    }

    /// Total cached bytes for a given video, or 0 if no entry / wrong id.
    /// Used by the preloader to decide when to pause downloading.
    func cachedByteCount(videoId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let entry, entry.videoId == videoId else { return 0 }
        return entry.cachedByteCount
    }

    /// Snapshot of the current entry's videoId, or nil if no entry.
    func currentVideoId() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return entry?.videoId
    }

    // MARK: - Writes

    /// Install an empty entry, replacing any existing one. Resets the playback
    /// offset tracker.
    func setEntry(videoId: String, startOffset: Int64, totalSize: Int64, contentType: String) {
        lock.lock()
        defer { lock.unlock() }
        entry = CacheEntry(
            videoId: videoId,
            chunks: [],
            cachedByteCount: 0,
            startOffset: startOffset,
            totalSize: totalSize,
            contentType: contentType
        )
        lastPlaybackOffset = 0
    }

    /// Append a chunk to the current entry, auto-trimming behind playback when
    /// the cache exceeds `trimThreshold`. Returns `false` when there is no
    /// entry or the entry's videoId doesn't match (chunk was dropped).
    @discardableResult
    func writeChunk(videoId: String, chunk: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var current = entry, current.videoId == videoId else { return false }
        current.chunks.append(chunk)
        current.cachedByteCount += chunk.count
        entry = current

        // Sliding window: trim chunks well behind playback position
        if current.cachedByteCount > Self.trimThreshold {
            trimFrontLocked(videoId: videoId)
        }
        return true
    }

    /// Update the playback-position tracker used by `trimFront` to know which
    /// bytes are safe to evict. No-op for mismatched videoId or zero duration.
    func updatePlaybackPosition(videoId: String, seconds: Double, duration: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard let entry, entry.videoId == videoId, duration > 0 else { return }
        let avgByterate = Double(entry.totalSize) / duration
        lastPlaybackOffset = Int64(seconds * avgByterate)
    }

    /// Drop complete chunks well behind playback position. O(1) per chunk — no
    /// large memmove. Returns bytes removed.
    @discardableResult
    func trimFront(videoId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return trimFrontLocked(videoId: videoId)
    }

    /// Emergency trim under memory pressure: aggressively shrink cache down to
    /// `targetSize` by dropping chunks from the front first. Returns bytes
    /// removed.
    @discardableResult
    func emergencyTrim(videoId: String, targetSize: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard var current = entry, current.videoId == videoId else { return 0 }
        guard current.cachedByteCount > targetSize else { return 0 }

        let overflow = current.cachedByteCount - targetSize
        // Walk chunks from front and accumulate until we've shed enough bytes.
        var bytesRemoved = 0
        var chunksToRemove = 0
        for c in current.chunks {
            if bytesRemoved >= overflow { break }
            bytesRemoved += c.count
            chunksToRemove += 1
        }
        guard chunksToRemove > 0 else { return 0 }

        current.chunks.removeFirst(chunksToRemove)
        current.cachedByteCount -= bytesRemoved
        current.startOffset += Int64(bytesRemoved)
        entry = current
        logger.info("Emergency-trimmed \(bytesRemoved / 1_000_000)MB from \(videoId) (target \(targetSize / 1_000_000)MB)")
        return bytesRemoved
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entry = nil
        lastPlaybackOffset = 0
        logger.info("Cache cleared")
    }

    // MARK: - Internal (lock already held)

    /// Caller must hold `lock`.
    @discardableResult
    private func trimFrontLocked(videoId: String) -> Int {
        guard var current = entry, current.videoId == videoId else { return 0 }
        let safeTrimBound = lastPlaybackOffset - Int64(Self.behindMargin)
        let maxTrimBytes = Int(safeTrimBound - current.startOffset)
        guard maxTrimBytes >= Self.minTrimSize else { return 0 }

        let trimBytes = min(maxTrimBytes, current.cachedByteCount - Self.maxCacheSize)
        guard trimBytes >= Self.minTrimSize else { return 0 }

        // Remove complete chunks from front
        let chunksToRemove = trimBytes / Self.chunkSize
        guard chunksToRemove > 0 else { return 0 }

        let bytesRemoved = current.chunks.prefix(chunksToRemove).reduce(0) { $0 + $1.count }
        current.chunks.removeFirst(chunksToRemove)
        current.cachedByteCount -= bytesRemoved
        current.startOffset += Int64(bytesRemoved)
        entry = current
        logger.info("Trimmed \(bytesRemoved / 1_000_000)MB from front of \(videoId)")
        return bytesRemoved
    }
}
