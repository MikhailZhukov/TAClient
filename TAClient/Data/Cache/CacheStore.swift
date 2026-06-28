import Foundation
import OSLog

private nonisolated let logger = Logger(subsystem: "ru.mzhukov.TAClient", category: "CacheStore")

/// Thread-safe synchronous storage layer underlying `VideoCachePreloader`.
///
/// Extracted from the original `VideoCache` actor (Task 9 / C1a) so the
/// `CachingResourceLoader` hot-read path can hit cache without an actor
/// executor hop. Task 10 / C1b switched loader + VM to use this type
/// directly; the preloader (renamed `VideoCachePreloader`) still delegates
/// through here.
///
/// Task 2 of the prefix-cache-region plan introduces multi-region support:
/// an entry may now hold a pinned `.prefix` region covering the file head
/// `[0, N)` as well as the sliding-window `.main` region from the resume
/// position forward. `setEntry` is now the single source of truth for the
/// region layout and computes `prefixSize` from `totalSize` via the
/// `clamp(totalSize × 0.01, 8 MB, 50 MB)` formula. Callers route writes
/// through `writeChunk(videoId:toRegion:_:)` and read region status via
/// `regionStatus(videoId:region:)`.
///
/// All mutable state (`entry`, `lastPlaybackOffset`) is protected by a
/// single `NSLock` held only for the duration of the critical section. No
/// async, no actor.
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
    static let prefixGrowthCap = 128_000_000 // soft cap on prefix size after promote-on-trim (initial size capped at maxPrefixSize=50 MB; promotes can grow it up to this)

    /// Lower bound for the dynamic prefix-region size (`8 MB`).
    static let minPrefixSize: Int64 = 8_000_000
    /// Upper bound for the dynamic prefix-region size (`50 MB`).
    static let maxPrefixSize: Int64 = 50_000_000

    /// Compute the size of the always-cached file-head region (the `.prefix`
    /// region) for a given total file size: `clamp(totalSize × 0.01, 8 MB,
    /// 50 MB)`. Exposed for the preloader and tests; pure function.
    static func computePrefixSize(totalSize: Int64) -> Int64 {
        let onePercent = Int64(Double(totalSize) * 0.01)
        return max(minPrefixSize, min(maxPrefixSize, onePercent))
    }

    // MARK: - Region types

    /// Identifies a cached byte range within a single video entry.
    ///
    /// Task 2 makes both `.prefix` and `.main` first-class regions. `.prefix`
    /// covers the always-cached file head `[0, N)` (pinned through sliding-
    /// window trim and `.warning` memory pressure). `.main` is the sliding-
    /// window region starting at `max(N, resumeByte)` and growing forward.
    enum RegionID: Hashable {
        case prefix
        case main

        /// Short stable name used in log lines, kept in sync with the bare
        /// string literals already used by `CacheStore`'s trim logs ("main").
        /// Prefer this over `String(describing:)` at call sites so log format
        /// stays uniform across files.
        var name: String {
            switch self {
            case .prefix: return "prefix"
            case .main: return "main"
            }
        }
    }

    /// A contiguous cached byte range stored as a sequence of fixed-size chunks.
    struct CacheRegion {
        let id: RegionID
        var startOffset: Int64           // byte offset where first chunk begins in the file
        var chunks: [Data]               // array of fixed-size chunks (each up to chunkSize)
        var cachedByteCount: Int = 0     // total bytes across all chunks
        var endOffset: Int64 { startOffset + Int64(cachedByteCount) }

        /// True when `offset` falls within the byte range currently held by
        /// this region (`[startOffset, endOffset)`).
        func contains(offset: Int64) -> Bool {
            offset >= startOffset && offset < endOffset
        }
    }

    // MARK: - CacheEntry

    struct CacheEntry {
        let videoId: String
        var regions: [RegionID: CacheRegion]
        var totalSize: Int64
        var contentType: String
    }

    // MARK: - State (protected by `lock`)

    private let lock = NSLock()
    private var entry: CacheEntry?
    private var lastPlaybackOffset: Int64 = 0

    init() {}

    // MARK: - Reads

    /// Read up to `length` bytes starting at `offset`. If `offset` falls inside
    /// a cached region but `length` would extend past that region's end (i.e.
    /// the request straddles a boundary into a different region or the gap
    /// between regions), only the bytes that lie inside the matched region are
    /// returned. AVPlayer treats short responses as "send more in a follow-up
    /// request" so this is safe and lets the loader hand out partial data
    /// without stitching across regions.
    func readData(videoId: String, offset: Int64, length: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry, entry.videoId == videoId else { return nil }
        guard let region = regionForLocked(entry: entry, offset: offset) else { return nil }

        let relativeOffset = Int(offset - region.startOffset)
        guard relativeOffset >= 0, relativeOffset < region.cachedByteCount else { return nil }

        // Cap the read to this region's data only. If the caller requested
        // bytes that span past `region.endOffset`, they get a short response.
        let maxAvailable = region.cachedByteCount - relativeOffset
        let bytesNeeded = min(length, maxAvailable)
        guard bytesNeeded > 0 else { return nil }

        // Walk chunks to find the one containing `relativeOffset`. Chunks are
        // usually `chunkSize`-uniform (the preloader's buffer-and-flush pattern
        // emits full chunks until the tail of a download, where one partial
        // chunk may land at the region's end). Promote-on-trim can splice a
        // prefix's partial tail into the middle of the chunks array, breaking
        // the previous `currentOffset / chunkSize` shortcut. Linear walk is
        // O(n) in chunk count but n is bounded (~600 in main, ~200 in prefix)
        // and reads are typically sequential, so the walk lives entirely in
        // L1 cache.
        var chunkStart = 0
        var chunkIdx = 0
        while chunkIdx < region.chunks.count {
            let chunkEnd = chunkStart + region.chunks[chunkIdx].count
            if relativeOffset < chunkEnd { break }
            chunkStart = chunkEnd
            chunkIdx += 1
        }
        guard chunkIdx < region.chunks.count else { return nil }

        var result = Data(capacity: bytesNeeded)
        var remaining = bytesNeeded
        var offsetInChunk = relativeOffset - chunkStart

        while remaining > 0, chunkIdx < region.chunks.count {
            let chunk = region.chunks[chunkIdx]
            let available = min(remaining, chunk.count - offsetInChunk)
            if available <= 0 { break }
            result.append(chunk[offsetInChunk..<(offsetInChunk + available)])

            remaining -= available
            chunkIdx += 1
            offsetInChunk = 0
        }

        return result.isEmpty ? nil : result
    }

    /// Status of the `.main` region only.
    ///
    /// Returns `nil` when there's no entry for `videoId`, when the videoId
    /// doesn't match, or when the entry has only a `.prefix` region (small-file
    /// edge case where `totalSize <= prefixSize`). Callers that need prefix
    /// info must use `regionStatus(videoId:region:)` explicitly — this avoids
    /// the ambiguity of "main if exists else prefix" silently changing meaning
    /// during the brief window when only prefix is seeded.
    func cacheStatus(videoId: String) -> (startOffset: Int64, endOffset: Int64, totalSize: Int64, contentType: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry, entry.videoId == videoId else { return nil }
        guard let region = entry.regions[.main] else { return nil }
        return (region.startOffset, region.endOffset, entry.totalSize, entry.contentType)
    }

    /// Per-region status accessor. Returns the start/end offsets, total file
    /// size, and content type for the requested region, or `nil` when the
    /// entry is missing / videoId doesn't match / the region wasn't created.
    func regionStatus(videoId: String, region: RegionID) -> (startOffset: Int64, endOffset: Int64, totalSize: Int64, contentType: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry, entry.videoId == videoId else { return nil }
        guard let r = entry.regions[region] else { return nil }
        return (r.startOffset, r.endOffset, entry.totalSize, entry.contentType)
    }

    /// Total cached bytes across ALL regions for a given video, or 0 if no
    /// entry / wrong id. Used by the preloader to decide when to pause
    /// downloading.
    func cachedByteCount(videoId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let entry, entry.videoId == videoId else { return 0 }
        return entry.regions.values.reduce(0) { $0 + $1.cachedByteCount }
    }

    /// Snapshot of the current entry's videoId, or nil if no entry.
    func currentVideoId() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return entry?.videoId
    }

    // MARK: - Writes

    /// Install a fresh entry, replacing any existing one. Resets the playback
    /// offset tracker.
    ///
    /// Region layout is computed from `totalSize` and `resumeByte`:
    /// - `prefixSize = clamp(totalSize × 0.01, 8 MB, 50 MB)`
    /// - if `totalSize > prefixSize`: creates BOTH `.prefix` (range `[0, prefixSize)`)
    ///   AND `.main` (starts at `max(prefixSize, resumeByte)`).
    /// - if `totalSize <= prefixSize`: creates ONLY `.prefix` (the whole file
    ///   fits in the prefix region; no main region needed).
    ///
    /// Both regions start empty (no chunks); writers append via
    /// `writeChunk(videoId:toRegion:_:)`.
    ///
    /// **Idempotency**: when called with a `videoId`, `totalSize`, AND
    /// `contentType` that all match the existing entry, this method is a
    /// no-op — the existing entry (regions, cached chunks, and
    /// `lastPlaybackOffset`) is preserved. LOAD-BEARING for the
    /// `.critical` → `restartPreloadIfNeeded` → `startPreloadWithRetry` →
    /// `downloadVideo` chain: the restart hook calls `resetMainRegion`
    /// first to anchor `.main` at the new playhead while preserving
    /// `.prefix`, then `downloadVideo` calls `setEntry` with identical
    /// `(videoId, totalSize, contentType)` from the HEAD probe. Without
    /// idempotency, that `setEntry` call wipes the prefix bytes that the
    /// soft-`.critical` policy was designed to preserve, opening a brief
    /// moov-cache-miss window where a scrub-after-resume can re-trigger
    /// the same freeze the two-region architecture exists to prevent.
    /// A `resumeByte` change alone is NOT enough to bust the cache — the
    /// existing main region's `startOffset` is already wherever
    /// `resetMainRegion` or a prior `setEntry` placed it; the caller is
    /// expected to use `resetMainRegion` for anchor changes, not a fresh
    /// `setEntry` with a new `resumeByte`.
    func setEntry(videoId: String, totalSize: Int64, contentType: String, resumeByte: Int64) {
        lock.lock()
        defer { lock.unlock() }

        if let existing = entry,
           existing.videoId == videoId,
           existing.totalSize == totalSize,
           existing.contentType == contentType {
            // Idempotent same-entry call. Preserve regions, chunks, and
            // lastPlaybackOffset. See the doc comment above for the
            // load-bearing reason this branch exists.
            return
        }

        let prefixSize = Self.computePrefixSize(totalSize: totalSize)
        // Clamp `resumeByte` into the file's byte range. Corrupt saved
        // progress, re-encoded video shrinking under us, or rounding past
        // duration can push `resumeByte` past `totalSize`; without this
        // clamp the main-region start would equal `totalSize`, producing a
        // degenerate region with `startOffset == endOffset == totalSize` and
        // (worse) trapping the preloader's `mainStart..<totalSize` range
        // construction before our empty-range guard can intervene. Round-trip
        // to `0` if negative as well, defensively.
        let clampedResumeByte = min(max(resumeByte, 0), totalSize)
        var regions: [RegionID: CacheRegion] = [:]

        // Always create the prefix region (covers the file head).
        let prefixRegion = CacheRegion(
            id: .prefix,
            startOffset: 0,
            chunks: [],
            cachedByteCount: 0
        )
        regions[.prefix] = prefixRegion

        // Create the main region only when the file extends past the prefix
        // AND the resume position leaves at least one byte for main to cover.
        // For small files (`totalSize <= prefixSize`) the prefix already
        // covers everything; when `clampedResumeByte >= totalSize` the main
        // region would be degenerate (zero-length, anchored at EOF) and
        // would later trip the preloader's pause-gate / read-path
        // assumptions. Skip it.
        if totalSize > prefixSize {
            let mainStart = max(prefixSize, clampedResumeByte)
            if mainStart < totalSize {
                let mainRegion = CacheRegion(
                    id: .main,
                    startOffset: mainStart,
                    chunks: [],
                    cachedByteCount: 0
                )
                regions[.main] = mainRegion
            }
        }

        entry = CacheEntry(
            videoId: videoId,
            regions: regions,
            totalSize: totalSize,
            contentType: contentType
        )
        lastPlaybackOffset = 0
    }

    /// Append a chunk to the named region, auto-trimming the `.main` region
    /// behind playback when its bytes exceed `trimThreshold`. Returns `false`
    /// when there is no entry, the entry's videoId doesn't match, or
    /// `toRegion` doesn't exist on the entry (chunk dropped).
    @discardableResult
    func writeChunk(videoId: String, toRegion: RegionID, chunk: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var current = entry, current.videoId == videoId else { return false }
        guard var region = current.regions[toRegion] else { return false }
        region.chunks.append(chunk)
        region.cachedByteCount += chunk.count
        current.regions[toRegion] = region
        entry = current

        // Sliding window applies only to the main region. Prefix is pinned —
        // it never gets trimmed by `writeChunk`.
        if toRegion == .main, region.cachedByteCount > Self.trimThreshold {
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

    /// Drop complete chunks well behind playback position from the `.main`
    /// region. O(1) per chunk — no large memmove. Returns bytes removed.
    /// Prefix is pinned and never trimmed.
    @discardableResult
    func trimFront(videoId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return trimFrontLocked(videoId: videoId)
    }

    /// Emergency trim under memory pressure: aggressively shrink the `.main`
    /// region down to `targetSize` by dropping chunks from the front first.
    /// Returns bytes removed. Prefix is pinned through `.warning` pressure.
    /// No-op when no `.main` region exists (small-file case).
    @discardableResult
    func emergencyTrim(videoId: String, targetSize: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard var current = entry, current.videoId == videoId else { return 0 }
        guard var region = current.regions[.main] else { return 0 }
        guard region.cachedByteCount > targetSize else { return 0 }

        let overflow = region.cachedByteCount - targetSize
        // Walk chunks from front and accumulate until we've shed enough bytes.
        var bytesRemoved = 0
        var chunksToRemove = 0
        for c in region.chunks {
            if bytesRemoved >= overflow { break }
            bytesRemoved += c.count
            chunksToRemove += 1
        }
        guard chunksToRemove > 0 else { return 0 }

        region.chunks.removeFirst(chunksToRemove)
        region.cachedByteCount -= bytesRemoved
        region.startOffset += Int64(bytesRemoved)
        current.regions[.main] = region
        entry = current
        logger.info("Emergency-trimmed \(bytesRemoved / 1_000_000)MB from main of \(videoId) (target \(targetSize / 1_000_000)MB)")
        return bytesRemoved
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entry = nil
        lastPlaybackOffset = 0
        logger.info("Cache cleared")
    }

    /// Replace the `.main` region with a fresh empty one anchored at
    /// `newStartOffset`. Keeps `.prefix` untouched (preserving moov-atom
    /// protection across large scrubs). Does NOT reset `lastPlaybackOffset` —
    /// trim math continues to operate from the same reference point.
    ///
    /// Clamping: `newStartOffset` is clamped into `[prefixEnd ?? 0, totalSize]`.
    /// If the clamped value equals `totalSize`, the `.main` region is REMOVED
    /// entirely (degenerate zero-length range at EOF).
    ///
    /// No-op for: missing entry, videoId mismatch, no `.main` region exists
    /// (small-file case where `totalSize <= prefixSize`).
    func resetMainRegion(videoId: String, newStartOffset: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard var current = entry, current.videoId == videoId else { return }
        // No-op when the entry has no `.main` region (small files where the
        // whole file fits inside `.prefix`).
        guard current.regions[.main] != nil else { return }

        // Clamp lower: never start before prefix ends, never before 0.
        let prefixEnd = current.regions[.prefix]?.endOffset ?? 0
        let lowerBound = max(Int64(0), prefixEnd)
        let totalSize = current.totalSize
        let clamped = min(max(newStartOffset, lowerBound), totalSize)

        let previousStart = current.regions[.main]?.startOffset ?? 0
        let previousEnd = current.regions[.main]?.endOffset ?? 0

        // Backward-into-prefix preserve: when the clamp raises
        // `newStartOffset` (a scrub byte that fell below `prefixEnd`) back up
        // to the existing `.main.startOffset`, wiping `.main` and re-seeding
        // an empty region at the SAME anchor would discard cached bytes for
        // no benefit. The caller's intent was "playback jumped backward
        // into the prefix region — make sure `.main` is anchored there",
        // and the existing main already satisfies that. Short-circuit and
        // keep the accumulated bytes.
        //
        // This only fires when `clamped == previousStart`. A forward scrub
        // past `previousEnd` produces a `clamped > previousStart` and falls
        // through to the rebuild path; a backward scrub into a region of
        // bytes the main has TRIMMED past (e.g. main = [500MB..580MB] and
        // user scrubs to byte 5MB → clamped = prefixEnd = 8MB ≠ 500MB) also
        // falls through. The short-circuit fires only for the specific
        // wasteful pattern: backward scrub into prefix when main is still
        // anchored at prefixEnd.
        if clamped == previousStart, current.regions[.main] != nil {
            // **Load-bearing for `VideoCachePreloader.reseedMain`'s
            // resume-from-tail fast path**: when this short-circuit fires,
            // both `startOffset` AND `endOffset` are preserved exactly. The
            // preloader re-reads `regionStatus(.main)` after calling us and
            // compares `(newMain.startOffset, newMain.endOffset)` against
            // `(previousStart, previousEnd)` to decide whether to spawn a
            // fresh download at `mainStart` or resume from the live tail
            // (`newMain.endOffset`). If a future refactor changes this branch
            // to (say) reset `endOffset` to `clamped` while preserving
            // `startOffset`, the preloader would re-fetch every byte from
            // `startOffset..<endOffset` even though they're already cached.
            // Keep the no-op a true no-op.
            logger.info("[Reseed] main keep @byte=\(clamped) (was [\(previousStart)..\(previousEnd))) for \(videoId) — already anchored")
            return
        }

        if clamped >= totalSize {
            // Degenerate: at EOF — remove `.main` entirely rather than create
            // a zero-length region that would later trip the preloader's
            // pause-gate / read-path assumptions.
            current.regions[.main] = nil
        } else {
            current.regions[.main] = CacheRegion(
                id: .main,
                startOffset: clamped,
                chunks: [],
                cachedByteCount: 0
            )
        }
        entry = current
        logger.info("[Reseed] main reset @byte=\(clamped) (was [\(previousStart)..\(previousEnd))) for \(videoId)")
    }

    // MARK: - Internal (lock already held)

    /// Find the region in `entry` that contains `offset`, or `nil` when no
    /// region covers it. Caller must hold `lock`.
    ///
    /// Lookup order: `.prefix` first (covers file head), then `.main`. This
    /// makes the implicit invariant that prefix and main never overlap an
    /// observable contract — if both regions ever cover the same offset, the
    /// one returned here is the prefix. (Per `setEntry`, `main.startOffset =
    /// max(prefixSize, resumeByte) >= prefix.endOffset`, so the regions are
    /// disjoint by construction.)
    private func regionForLocked(entry: CacheEntry, offset: Int64) -> CacheRegion? {
        if let prefix = entry.regions[.prefix], prefix.contains(offset: offset) {
            return prefix
        }
        if let main = entry.regions[.main], main.contains(offset: offset) {
            return main
        }
        return nil
    }

    /// Public locked variant of `regionForLocked` exposed for tests; takes the
    /// lock internally and returns a snapshot copy of the matching region.
    /// Returns `nil` when no entry / wrong videoId / no region covers
    /// `offset`.
    func regionFor(videoId: String, offset: Int64) -> CacheRegion? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry, entry.videoId == videoId else { return nil }
        return regionForLocked(entry: entry, offset: offset)
    }

    /// Caller must hold `lock`. Trims main's front; if main is adjacent to
    /// prefix (`prefix.endOffset == main.startOffset`) and prefix is under
    /// `maxPrefixSize`, promotes the trimmed chunks to prefix's tail instead
    /// of discarding them. This keeps the cache contiguous across the prefix/main
    /// boundary and eliminates the gap that AVPlayer's moov re-reads can fall
    /// into after long playback. When prefix is at cap or main is not adjacent,
    /// trimmed chunks are discarded as before.
    @discardableResult
    private func trimFrontLocked(videoId: String) -> Int {
        guard var current = entry, current.videoId == videoId else { return 0 }
        guard var region = current.regions[.main] else { return 0 }
        let safeTrimBound = lastPlaybackOffset - Int64(Self.behindMargin)
        let maxTrimBytes = Int(safeTrimBound - region.startOffset)
        guard maxTrimBytes >= Self.minTrimSize else { return 0 }

        let trimBytes = min(maxTrimBytes, region.cachedByteCount - Self.maxCacheSize)
        guard trimBytes >= Self.minTrimSize else { return 0 }

        // Remove complete chunks from front
        let chunksToRemove = trimBytes / Self.chunkSize
        guard chunksToRemove > 0 else { return 0 }

        // Determine how many of the to-be-trimmed chunks can be promoted into
        // prefix. Conditions: (1) prefix exists, (2) prefix.endOffset ==
        // main.startOffset (no gap to bridge across), (3) prefix is below its
        // soft cap. Promoted chunks extend prefix's tail; the rest are
        // discarded.
        var chunksToPromote = 0
        var promotedBytes = 0
        if var prefix = current.regions[.prefix],
           prefix.endOffset == region.startOffset,
           prefix.cachedByteCount < Self.prefixGrowthCap {
            let headroom = Self.prefixGrowthCap - prefix.cachedByteCount
            for chunk in region.chunks.prefix(chunksToRemove) {
                if promotedBytes + chunk.count > headroom { break }
                chunksToPromote += 1
                promotedBytes += chunk.count
            }
            if chunksToPromote > 0 {
                prefix.chunks.append(contentsOf: region.chunks.prefix(chunksToPromote))
                prefix.cachedByteCount += promotedBytes
                current.regions[.prefix] = prefix
            }
        }

        let bytesRemovedFromMain = region.chunks.prefix(chunksToRemove).reduce(0) { $0 + $1.count }
        region.chunks.removeFirst(chunksToRemove)
        region.cachedByteCount -= bytesRemovedFromMain
        region.startOffset += Int64(bytesRemovedFromMain)
        current.regions[.main] = region
        entry = current

        let discarded = bytesRemovedFromMain - promotedBytes
        if promotedBytes > 0 && discarded > 0 {
            logger.info("Trimmed \(bytesRemovedFromMain / 1_000_000)MB from main (promoted \(promotedBytes / 1_000_000)MB to prefix, discarded \(discarded / 1_000_000)MB) for \(videoId)")
        } else if promotedBytes > 0 {
            logger.info("Trimmed \(bytesRemovedFromMain / 1_000_000)MB from main (all promoted to prefix) for \(videoId)")
        } else {
            logger.info("Trimmed \(bytesRemovedFromMain / 1_000_000)MB from front of main for \(videoId)")
        }
        return bytesRemovedFromMain
    }
}
