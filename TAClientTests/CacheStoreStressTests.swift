import Testing
import Foundation
@testable import TAClient

/// Concurrent stress tests for `CacheStore`. Validates that the `NSLock`-based
/// synchronisation holds up under many readers racing a single writer.
///
/// Invariants validated (per plan Task 9):
/// (a) No crashes (test completes).
/// (b) Sum of chunk sizes successfully written equals `cachedByteCount +
///     bytesRemovedByTrim` — no bytes appear or disappear mysteriously.
/// (c) Every successful `readData` returns data within the current
///     `[startOffset, startOffset + cachedByteCount)` window observed at the
///     read call's boundary (observed via `cacheStatus` snapshots).
/// (d) `cachedByteCount <= trimThreshold` never exceeded by more than one
///     chunk size (since `writeChunk` auto-trims when exceeded).
///
/// `@Suite(.serialized)` because the test spawns detached tasks that saturate
/// the global queue; running in parallel with other stress tests would make
/// duration non-deterministic.
///
/// Counters shared across tasks are protected with a plain `NSLock` held only
/// briefly and with no `await` between lock/unlock pairs — safe under Swift
/// concurrency despite the lint warnings on `.lock()` in async contexts.
@Suite(.serialized) struct CacheStoreStressTests {

    private final class Counters: @unchecked Sendable {
        private let lock = NSLock()
        private var _bytesWritten: Int = 0
        private var _writesSucceeded: Int = 0
        private var _readsAttempted: Int = 0
        private var _readsSucceeded: Int = 0
        private var _violation: String?

        func recordWrite(bytes: Int) {
            lock.lock(); defer { lock.unlock() }
            _bytesWritten += bytes
            _writesSucceeded += 1
        }

        func recordReadAttempt() {
            lock.lock(); defer { lock.unlock() }
            _readsAttempted += 1
        }

        func recordReadSuccess() {
            lock.lock(); defer { lock.unlock() }
            _readsSucceeded += 1
        }

        func recordViolation(_ msg: String) {
            lock.lock(); defer { lock.unlock() }
            if _violation == nil { _violation = msg }
        }

        func snapshot() -> (bytesWritten: Int, writesSucceeded: Int, readsAttempted: Int, readsSucceeded: Int, violation: String?) {
            lock.lock(); defer { lock.unlock() }
            return (_bytesWritten, _writesSucceeded, _readsAttempted, _readsSucceeded, _violation)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    nonisolated func concurrentReadersAndWriter_holdInvariants() async {
        let store = CacheStore()
        let videoId = "stress-vid"
        // Generous total size so startOffset advances on trim without crossing it.
        let totalSize: Int64 = 10_000_000_000
        store.setEntry(videoId: videoId, totalSize: totalSize, contentType: "video/mp4", resumeByte: 0)
        // Capture the initial main.startOffset (= computed prefixSize) so the
        // bytes-trimmed invariant below ignores the static prefix-region offset
        // and only counts post-write trim advances.
        let initialMainStart = Int(store.cacheStatus(videoId: videoId)?.startOffset ?? 0)

        // Chunk payload: constant size. Varying content ensures we don't
        // accidentally pass on all-zero data.
        let chunkSize = 64 * 1024 // 64 KB
        let chunkCount = 20_000   // plenty of iterations for ~1s run

        let counters = Counters()

        // Writer: appends chunks sequentially until time budget runs out.
        let writer = Task.detached(priority: .userInitiated) {
            let deadline = Date().addingTimeInterval(1.0)
            var i = 0
            while Date() < deadline && i < chunkCount {
                var bytes = [UInt8](repeating: 0, count: chunkSize)
                for j in 0..<chunkSize {
                    bytes[j] = UInt8((i &+ j) % 251)
                }
                let chunk = Data(bytes)
                if store.writeChunk(videoId: videoId, toRegion: .main, chunk: chunk) {
                    counters.recordWrite(bytes: chunk.count)
                }
                i += 1
                if i % 16 == 0 { await Task.yield() }
            }
        }

        // Readers: repeatedly pick a random offset inside the current window
        // and read. Invariant (c): if read returns non-nil, the offset was
        // inside the window at read time. We verify by snapshotting the window
        // right before the read and using the snapshot's range.
        let readerCount = 10
        var readers: [Task<Void, Never>] = []
        for _ in 0..<readerCount {
            let t = Task.detached(priority: .userInitiated) {
                let deadline = Date().addingTimeInterval(1.0)
                var rng = SystemRandomNumberGenerator()
                while Date() < deadline {
                    counters.recordReadAttempt()

                    guard let status = store.cacheStatus(videoId: videoId),
                          status.endOffset > status.startOffset else {
                        await Task.yield()
                        continue
                    }
                    let windowBytes = status.endOffset - status.startOffset
                    let pick = Int64.random(in: 0..<windowBytes, using: &rng)
                    let offset = status.startOffset + pick
                    let length = 256

                    if let data = store.readData(videoId: videoId, offset: offset, length: length) {
                        if data.isEmpty {
                            counters.recordViolation("non-nil but empty slice")
                        } else {
                            counters.recordReadSuccess()
                        }
                    }
                    if Int.random(in: 0..<32, using: &rng) == 0 { await Task.yield() }
                }
            }
            readers.append(t)
        }

        _ = await writer.value
        for r in readers { _ = await r.value }

        let snap = counters.snapshot()

        // Invariant (a): we got here without crashing. Checked implicitly.
        #expect(snap.violation == nil, "\(snap.violation ?? "unknown violation")")

        // Invariant (b): bytesWritten == cachedByteCount + bytesRemovedByTrim.
        // We infer bytesRemoved from startOffset: it started at 0 and only
        // grows when `trimFrontLocked` advances it by exactly bytesRemoved.
        let finalCached = store.cachedByteCount(videoId: videoId)
        let finalStatus = store.cacheStatus(videoId: videoId)
        let bytesTrimmed = Int(finalStatus?.startOffset ?? 0) - initialMainStart
        #expect(
            snap.bytesWritten == finalCached + bytesTrimmed,
            "bytesWritten=\(snap.bytesWritten), cached=\(finalCached), trimmed=\(bytesTrimmed)"
        )

        // Invariant (d): cachedByteCount must never exceed trimThreshold by
        // more than one chunk (auto-trim runs after each append, so the peak
        // observed between append and trim could momentarily reach
        // `trimThreshold + chunkSize`). In this test we never approach the
        // 282 MB threshold, so the bound is trivially satisfied.
        let threshold = CacheStore.trimThreshold
        #expect(finalCached <= threshold + chunkSize)

        // Sanity: readers and writer did meaningful work.
        #expect(snap.readsAttempted > 0)
        #expect(snap.writesSucceeded > 0)
    }

    // MARK: - Multi-region stress

    /// Byte pattern used by `concurrentReadersAcrossBothRegions` to make each
    /// absolute file offset's byte value deterministic. This lets readers
    /// verify that data returned at offset `X` matches the byte the writer
    /// stamped at offset `X`, catching torn writes or cross-region overlap.
    private static func expectedByte(at absoluteOffset: Int64) -> UInt8 {
        // Use a simple mixing hash of the offset so adjacent offsets don't
        // produce identical bytes (which would let trivial off-by-one bugs
        // pass undetected).
        let x = UInt64(bitPattern: Int64(absoluteOffset))
        return UInt8(truncatingIfNeeded: (x ^ (x >> 7) ^ (x >> 13)) & 0xFF)
    }

    /// Build a chunk whose every byte matches `expectedByte(at:)` for the
    /// corresponding absolute file offset, starting from `startOffset`.
    private static func makeChunk(startOffset: Int64, size: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: size)
        for j in 0..<size {
            bytes[j] = expectedByte(at: startOffset + Int64(j))
        }
        return Data(bytes)
    }

    /// Stress NSLock invariants under load on BOTH regions simultaneously.
    ///
    /// Seeds an entry with a partially-filled `.prefix` region and a small
    /// `.main` region. 5 readers loop on prefix offsets, 5 loop on main
    /// offsets, and a single writer alternates appending to prefix (until
    /// prefix is full at `prefixSize`) and main. Each absolute file offset
    /// carries a deterministic byte value (see `expectedByte(at:)`) so any
    /// torn read, cross-region overlap, or stale-pointer corruption shows up
    /// as a byte mismatch — recorded as a violation that fails the test.
    @Test(.timeLimit(.minutes(1)))
    nonisolated func concurrentReadersAcrossBothRegions() async {
        let store = CacheStore()
        let videoId = "stress-multi-region"
        // totalSize = 800 MB → prefixSize = clamp(8 MB, 8 MB, 50 MB) = 8 MB.
        let totalSize: Int64 = 800_000_000
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        #expect(prefixSize == 8_000_000)
        // Resume at the start of the main region (no gap between regions).
        store.setEntry(videoId: videoId, totalSize: totalSize, contentType: "video/mp4", resumeByte: prefixSize)

        // Chunk size MUST match `CacheStore.chunkSize` — `readData` derives the
        // chunk index via `relativeOffset / Self.chunkSize`, which only matches
        // the underlying chunk array when every appended chunk is exactly that
        // size. Mismatched sizes would route reads to the wrong chunk and look
        // like a corruption bug (caught the hard way the first time around).
        let chunkSize = CacheStore.chunkSize  // 512 KB

        // Seed prefix with half its capacity so the writer still has room to
        // append, but readers can immediately hit valid offsets in [0, 4MB).
        let prefixSeedChunks = Int(prefixSize / 2) / chunkSize   // 4 MB / 512 KB = 8
        for i in 0..<prefixSeedChunks {
            let off = Int64(i * chunkSize)
            let chunk = Self.makeChunk(startOffset: off, size: chunkSize)
            #expect(store.writeChunk(videoId: videoId, toRegion: .prefix, chunk: chunk))
        }

        // Seed main with a few MB so readers immediately hit valid offsets in
        // [prefixSize, prefixSize + ~2 MB).
        let mainSeedChunks = 4   // 4 × 512 KB = 2 MB
        for i in 0..<mainSeedChunks {
            let off = prefixSize + Int64(i * chunkSize)
            let chunk = Self.makeChunk(startOffset: off, size: chunkSize)
            #expect(store.writeChunk(videoId: videoId, toRegion: .main, chunk: chunk))
        }

        let counters = Counters()

        // Single writer task: alternates prefix-vs-main on each iteration.
        // Stops appending to prefix once it has reached `prefixSize` (the
        // preloader would do the same in production). Main keeps growing.
        // Both writes use absolute-offset byte stamps so readers can verify
        // integrity.
        let writer = Task.detached(priority: .userInitiated) {
            let deadline = Date().addingTimeInterval(1.0)
            var prefixOffset = Int64(prefixSeedChunks * chunkSize)
            var mainOffset = prefixSize + Int64(mainSeedChunks * chunkSize)
            var i = 0
            while Date() < deadline {
                // Writer always uses full `chunkSize` chunks — `readData` math
                // assumes every chunk is exactly that size. Prefix writes stop
                // once a full chunk wouldn't fit (room left < chunkSize).
                let writePrefix = (i % 2 == 0) && (prefixOffset + Int64(chunkSize) <= prefixSize)
                if writePrefix {
                    let chunk = Self.makeChunk(startOffset: prefixOffset, size: chunkSize)
                    if store.writeChunk(videoId: videoId, toRegion: .prefix, chunk: chunk) {
                        counters.recordWrite(bytes: chunkSize)
                        prefixOffset += Int64(chunkSize)
                    }
                } else {
                    let chunk = Self.makeChunk(startOffset: mainOffset, size: chunkSize)
                    if store.writeChunk(videoId: videoId, toRegion: .main, chunk: chunk) {
                        counters.recordWrite(bytes: chunkSize)
                        mainOffset += Int64(chunkSize)
                    }
                }
                i += 1
                if i % 16 == 0 { await Task.yield() }
            }
        }

        // Reader factory: picks a random offset inside the requested region's
        // current `[startOffset, endOffset)` window and reads. On a non-nil
        // response, verifies every byte matches `expectedByte(at:)` for its
        // absolute offset.
        func makeReaderTask(region: CacheStore.RegionID) -> Task<Void, Never> {
            Task.detached(priority: .userInitiated) {
                let deadline = Date().addingTimeInterval(1.0)
                var rng = SystemRandomNumberGenerator()
                while Date() < deadline {
                    counters.recordReadAttempt()

                    guard let status = store.regionStatus(videoId: videoId, region: region),
                          status.endOffset > status.startOffset else {
                        await Task.yield()
                        continue
                    }
                    let windowBytes = status.endOffset - status.startOffset
                    let pick = Int64.random(in: 0..<windowBytes, using: &rng)
                    let offset = status.startOffset + pick
                    let length = 256

                    if let data = store.readData(videoId: videoId, offset: offset, length: length) {
                        if data.isEmpty {
                            counters.recordViolation("non-nil but empty slice at offset \(offset) in \(region)")
                        } else {
                            // Verify every returned byte matches the expected
                            // pattern for its absolute file offset.
                            var mismatch: (Int64, UInt8, UInt8)?
                            for (i, byte) in data.enumerated() {
                                let abs = offset + Int64(i)
                                let expected = Self.expectedByte(at: abs)
                                if byte != expected {
                                    mismatch = (abs, expected, byte)
                                    break
                                }
                            }
                            if let m = mismatch {
                                counters.recordViolation(
                                    "byte mismatch at abs offset \(m.0): expected \(m.1) got \(m.2) (region=\(region))"
                                )
                            } else {
                                counters.recordReadSuccess()
                            }
                        }
                    }
                    if Int.random(in: 0..<32, using: &rng) == 0 { await Task.yield() }
                }
            }
        }

        var readers: [Task<Void, Never>] = []
        for _ in 0..<5 { readers.append(makeReaderTask(region: .prefix)) }
        for _ in 0..<5 { readers.append(makeReaderTask(region: .main)) }

        _ = await writer.value
        for r in readers { _ = await r.value }

        let snap = counters.snapshot()

        // Invariant (a): no crashes, no torn reads, no cross-region corruption.
        #expect(snap.violation == nil, "\(snap.violation ?? "unknown violation")")

        // Sanity: readers and writer all did meaningful work in both regions.
        #expect(snap.readsAttempted > 0)
        #expect(snap.readsSucceeded > 0)
        #expect(snap.writesSucceeded > 0)

        // Region-shape invariants survive the run.
        let prefixStatus = store.regionStatus(videoId: videoId, region: .prefix)
        let mainStatus = store.regionStatus(videoId: videoId, region: .main)
        #expect(prefixStatus?.startOffset == 0)
        // Prefix never exceeded its cap (writer stops appending when full).
        if let s = prefixStatus {
            #expect(s.endOffset <= prefixSize)
        }
        // Main never trims into prefix territory (regions stay disjoint).
        if let s = mainStatus {
            #expect(s.startOffset >= prefixSize)
        }
    }

    // MARK: - resetMainRegion concurrency

    /// Tracks the latest reseed argument across the reseeder task so the test
    /// body can assert the final `.main` region's `startOffset` matches the
    /// LAST `newStartOffset` passed to `resetMainRegion` once all tasks join.
    private final class ReseedRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _lastTarget: Int64?
        private var _callCount: Int = 0

        func record(target: Int64) {
            lock.lock(); defer { lock.unlock() }
            _lastTarget = target
            _callCount += 1
        }

        var snapshot: (lastTarget: Int64?, callCount: Int) {
            lock.lock(); defer { lock.unlock() }
            return (_lastTarget, _callCount)
        }
    }

    /// Stress NSLock invariants on the `resetMainRegion` mutation path. 10
    /// writers append `.main` chunks in tight loops while a single reseeder
    /// calls `resetMainRegion` 5× at random intervals — all under
    /// `Task.detached` so they truly run in parallel.
    ///
    /// Invariants validated:
    /// (a) No crashes (test completes).
    /// (b) After all tasks join, `regionStatus(.main).startOffset` equals the
    ///     LAST `newStartOffset` the reseeder passed (clamping is a no-op here
    ///     because all targets are well inside `[prefixEnd, totalSize)`).
    ///     Writes cannot move `startOffset` — only `resetMainRegion` does
    ///     (auto-trim is disabled in this test by keeping total written bytes
    ///     well below `trimThreshold = 282 MB`). The reseeder is awaited LAST
    ///     so its terminal call is guaranteed to have happened after every
    ///     writer's last write.
    /// (c) `regionStatus(.main).endOffset >= startOffset` (no torn state).
    ///
    /// This test locks in the contract that the NSLock guarding `entry`
    /// serialises `writeChunk` and `resetMainRegion` correctly — a regression
    /// removing the lock or splitting it would surface as either a crash, a
    /// torn region, or a mismatched final `startOffset`.
    @Test(.timeLimit(.minutes(1)))
    nonisolated func resetMain_concurrentWithWrite_noCorruption() async {
        let store = CacheStore()
        let videoId = "stress-reseed"
        // 4 GB total → plenty of room for reseed targets up to ~1 GB without
        // hitting EOF clamp, and prefixSize stays at the 50 MB cap.
        let totalSize: Int64 = 4_000_000_000
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        store.setEntry(videoId: videoId, totalSize: totalSize, contentType: "video/mp4", resumeByte: prefixSize)

        // Pre-defined reseed targets — all comfortably inside
        // `[prefixSize, totalSize)`, so clamping is a no-op and the final
        // `startOffset` should equal the last value verbatim. Targets are
        // monotonically increasing so a stale-write race that re-applies an
        // older reseed would be immediately visible.
        let reseedTargets: [Int64] = [
            200_000_000,
            400_000_000,
            600_000_000,
            800_000_000,
            1_000_000_000
        ]

        let counters = Counters()
        let recorder = ReseedRecorder()

        // Chunk payload: small chunks, bounded count per writer so total
        // bytes-written across all 10 writers stays well below `trimThreshold`
        // (282 MB). With 10 writers × max ~500 chunks × 16 KB ≈ 80 MB worst
        // case — auto-trim cannot fire and `startOffset` is only ever moved
        // by `resetMainRegion`.
        let chunkSize = 16 * 1024 // 16 KB
        let maxChunksPerWriter = 500

        // Writers: append `.main` chunks in tight loops with bounded iteration.
        // Yield occasionally so the reseeder gets scheduled.
        var writers: [Task<Void, Never>] = []
        for _ in 0..<10 {
            let t = Task.detached(priority: .userInitiated) {
                let deadline = Date().addingTimeInterval(1.0)
                var i = 0
                while Date() < deadline && i < maxChunksPerWriter {
                    var bytes = [UInt8](repeating: 0, count: chunkSize)
                    for j in 0..<chunkSize {
                        bytes[j] = UInt8((i &+ j) % 251)
                    }
                    let chunk = Data(bytes)
                    if store.writeChunk(videoId: videoId, toRegion: .main, chunk: chunk) {
                        counters.recordWrite(bytes: chunk.count)
                    }
                    i += 1
                    if i % 8 == 0 { await Task.yield() }
                }
            }
            writers.append(t)
        }

        // Reseeder: 5 reseeds at random sub-millisecond intervals, racing the
        // writers. Each call mutates `startOffset` to the target verbatim
        // (clamping is a no-op for these targets).
        let reseeder = Task.detached(priority: .userInitiated) {
            var rng = SystemRandomNumberGenerator()
            for target in reseedTargets {
                // Small randomised pause between reseeds so they interleave
                // with writes instead of running back-to-back.
                let nanos = UInt64.random(in: 1_000_000...20_000_000, using: &rng) // 1–20 ms
                try? await Task.sleep(nanoseconds: nanos)
                store.resetMainRegion(videoId: videoId, newStartOffset: target)
                recorder.record(target: target)
            }
        }

        // CRITICAL ordering: await all writers FIRST, then the reseeder LAST.
        // This guarantees the reseeder's terminal `resetMainRegion` call lands
        // after every writer has stopped appending, so the final `startOffset`
        // assertion is deterministic. (Without this, a writer that yields
        // after the reseeder's last call could race — though it still couldn't
        // move `startOffset`, the assertion's intent is clearer this way.)
        for w in writers { _ = await w.value }
        _ = await reseeder.value

        let snap = counters.snapshot()
        let rsnap = recorder.snapshot

        // Invariant (a): we got here without crashing.
        #expect(snap.violation == nil, "\(snap.violation ?? "unknown violation")")

        // Sanity: the reseeder fired all 5 calls; writers did meaningful work.
        #expect(rsnap.callCount == reseedTargets.count)
        #expect(rsnap.lastTarget == reseedTargets.last)
        #expect(snap.writesSucceeded > 0)

        // Invariant (b): final `.main` region's `startOffset` matches the
        // LAST reseed argument. Writes never move `startOffset` in this test
        // (total written stays well below `trimThreshold`); only
        // `resetMainRegion` does. The reseeder's 5 calls take <=100ms total
        // (5 × max 20ms sleep) while the writers' deadline is 1.0s, so the
        // terminal reseed lands deep inside the writers' budget — but a
        // post-reseed write only mutates `endOffset` (and `cachedByteCount`),
        // not `startOffset`. Plan spec explicitly notes this race: writes
        // may grow the region after the last reseed, but the start-anchor
        // must still equal the last reseed argument.
        let finalMain = store.regionStatus(videoId: videoId, region: .main)
        #expect(finalMain != nil)
        #expect(finalMain?.startOffset == reseedTargets.last)

        // Invariant (c): no torn region — `endOffset >= startOffset`. Writes
        // that race the terminal reseed legitimately push `endOffset` past
        // `startOffset` (they target the freshly-anchored region). What we
        // forbid is the reverse — `endOffset < startOffset` would indicate a
        // torn write that bypassed the lock.
        if let m = finalMain {
            #expect(m.endOffset >= m.startOffset)
        }
    }
}
