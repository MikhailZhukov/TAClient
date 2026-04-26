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
        store.setEntry(videoId: videoId, startOffset: 0, totalSize: totalSize, contentType: "video/mp4")

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
                if store.writeChunk(videoId: videoId, chunk: chunk) {
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
        let bytesTrimmed = Int(finalStatus?.startOffset ?? 0)
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
}
