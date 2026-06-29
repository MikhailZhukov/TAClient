import Testing
import Foundation
@testable import TAClient

/// Direct tests for the synchronous `CacheStore` API introduced in Task 9
/// (C1a). The baseline tests in `VideoCachePreloaderTests` exercise the store
/// end-to-end through the preloader; these tests exercise each method in
/// isolation under known conditions.
///
/// `CacheStore` has no shared global state (every test uses its own instance)
/// so these tests do not need to serialise.
///
/// Task 2 (prefix-cache-region) introduced multi-region support: an entry can
/// hold a pinned `.prefix` region covering byte `[0, N)` plus a sliding-window
/// `.main` region starting at `max(N, resumeByte)`. `setEntry`'s parameter
/// list changed to `(videoId:totalSize:contentType:resumeByte:)` and
/// `writeChunk` now requires an explicit `toRegion:` argument. The tests below
/// were migrated as part of Task 2.
@Suite struct CacheStoreTests {

    // MARK: - Helpers

    /// Byte i = UInt8(i % 251). Deterministic and distinct across 8-bit values.
    private static func makePayload(size: Int) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(size)
        for i in 0..<size {
            bytes.append(UInt8(i % 251))
        }
        return Data(bytes)
    }

    /// Set up a fresh entry AND fill it: writes `payload` into the named
    /// region as a sequence of fixed-size chunks. Defaults to writing into
    /// `.prefix` and using a `totalSize` that fits inside the prefix lower
    /// bound (8 MB) so only the prefix region is created — keeps single-region
    /// tests simple. Pass a larger `totalSize` (with a `region: .main` and a
    /// matching `resumeByte`) to drive multi-region scenarios.
    private static func setEntryAndFill(
        store: CacheStore,
        videoId: String,
        totalSize: Int64? = nil,
        contentType: String = "video/mp4",
        resumeByte: Int64 = 0,
        region: CacheStore.RegionID = .prefix,
        payload: Data,
        chunkSize: Int = CacheStore.chunkSize
    ) {
        let total = totalSize ?? Int64(payload.count) + resumeByte
        store.setEntry(
            videoId: videoId,
            totalSize: total,
            contentType: contentType,
            resumeByte: resumeByte
        )
        var offset = 0
        while offset < payload.count {
            let end = min(offset + chunkSize, payload.count)
            let chunk = payload[offset..<end]
            _ = store.writeChunk(videoId: videoId, toRegion: region, chunk: Data(chunk))
            offset = end
        }
    }

    // MARK: - Reads

    @Test func readData_happyPath_returnsExactBytes() {
        let store = CacheStore()
        let payload = Self.makePayload(size: 4096)
        Self.setEntryAndFill(store: store, videoId: "v", payload: payload)

        let slice = store.readData(videoId: "v", offset: 100, length: 256)
        #expect(slice?.count == 256)
        #expect(slice == payload[100..<356])
    }

    @Test func readData_spansChunkBoundary_returnsContiguousData() {
        let store = CacheStore()
        // Size chosen to straddle the 512KB chunk boundary
        let payload = Self.makePayload(size: 600 * 1024)
        Self.setEntryAndFill(store: store, videoId: "v", payload: payload)

        let offset: Int64 = Int64(CacheStore.chunkSize) - 128
        let slice = store.readData(videoId: "v", offset: offset, length: 256)
        #expect(slice?.count == 256)
        let expected = payload[Int(offset)..<Int(offset) + 256]
        #expect(slice == Data(expected))
    }

    @Test func readData_lengthLargerThanAvailable_returnsOnlyAvailable() {
        let store = CacheStore()
        let payload = Self.makePayload(size: 1024)
        Self.setEntryAndFill(store: store, videoId: "v", payload: payload)

        // Request beyond end: should clamp to what's available.
        let slice = store.readData(videoId: "v", offset: 900, length: 4096)
        #expect(slice?.count == 124)
        #expect(slice == payload.suffix(124))
    }

    @Test func readData_offsetPastEnd_returnsNil() {
        let store = CacheStore()
        let payload = Self.makePayload(size: 1024)
        Self.setEntryAndFill(store: store, videoId: "v", payload: payload)

        #expect(store.readData(videoId: "v", offset: 1025, length: 16) == nil)
        #expect(store.readData(videoId: "v", offset: 1024, length: 16) == nil) // exactly at end
    }

    @Test func readData_negativeOffset_returnsNil() {
        let store = CacheStore()
        let payload = Self.makePayload(size: 1024)
        Self.setEntryAndFill(store: store, videoId: "v", payload: payload)

        #expect(store.readData(videoId: "v", offset: -1, length: 16) == nil)
    }

    @Test func readData_offsetBeforeMainStartOffset_returnsNil() {
        // Migrated from `readData_offsetBeforeStartOffset_returnsNil`. Under the
        // new region layout we test "in main's range but before main's
        // startOffset" by using a large file (forcing both regions) and writing
        // only to `.main` from its non-zero startOffset. Reads at offsets >=
        // prefixSize but < main.startOffset must return nil — they fall in the
        // gap between prefix and main and no chunks cover them.
        let store = CacheStore()
        let totalSize: Int64 = 100 * 1024 * 1024 // 100 MB → both regions
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        let resumeByte = prefixSize + 5_000  // main starts here
        store.setEntry(
            videoId: "v",
            totalSize: totalSize,
            contentType: "video/mp4",
            resumeByte: resumeByte
        )
        let chunk = Data(repeating: 0xAB, count: 1024)
        _ = store.writeChunk(videoId: "v", toRegion: .main, chunk: chunk)

        // In the gap between prefix.endOffset (= prefixSize, no chunks written)
        // and main.startOffset (= resumeByte): no region covers; read returns nil.
        #expect(store.readData(videoId: "v", offset: prefixSize, length: 16) == nil)
        #expect(store.readData(videoId: "v", offset: resumeByte - 1, length: 16) == nil)
    }

    @Test func readData_wrongVideoId_returnsNil() {
        let store = CacheStore()
        let payload = Self.makePayload(size: 1024)
        Self.setEntryAndFill(store: store, videoId: "v", payload: payload)

        #expect(store.readData(videoId: "other", offset: 0, length: 16) == nil)
    }

    @Test func readData_noEntry_returnsNil() {
        let store = CacheStore()
        #expect(store.readData(videoId: "v", offset: 0, length: 16) == nil)
    }

    // MARK: - cacheStatus / cachedByteCount / currentVideoId

    @Test func cacheStatus_returnsMainStatus_whenMainExists() {
        // Migrated from `cacheStatus_returnsCorrectRange`. The new contract:
        // `cacheStatus` returns ONLY main's status; small files (totalSize <=
        // prefixSize) where there's no main region get a nil response.
        let store = CacheStore()
        let totalSize: Int64 = 100 * 1024 * 1024
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        let resumeByte = prefixSize + 1_000
        let payload = Self.makePayload(size: 2048)
        Self.setEntryAndFill(
            store: store,
            videoId: "v",
            totalSize: totalSize,
            contentType: "video/mp4",
            resumeByte: resumeByte,
            region: .main,
            payload: payload
        )
        let status = store.cacheStatus(videoId: "v")
        #expect(status?.startOffset == resumeByte)
        #expect(status?.endOffset == resumeByte + 2_048)
        #expect(status?.totalSize == totalSize)
        #expect(status?.contentType == "video/mp4")
    }

    @Test func cacheStatus_wrongVideoId_returnsNil() {
        let store = CacheStore()
        let payload = Self.makePayload(size: 1024)
        Self.setEntryAndFill(store: store, videoId: "v", payload: payload)
        #expect(store.cacheStatus(videoId: "other") == nil)
    }

    @Test func cachedByteCount_reflectsWrittenChunks() {
        let store = CacheStore()
        let payload = Self.makePayload(size: 3_000)
        Self.setEntryAndFill(store: store, videoId: "v", payload: payload, chunkSize: 512)

        #expect(store.cachedByteCount(videoId: "v") == 3_000)
        #expect(store.cachedByteCount(videoId: "other") == 0)
    }

    @Test func currentVideoId_reflectsActiveEntry() {
        let store = CacheStore()
        #expect(store.currentVideoId() == nil)
        Self.setEntryAndFill(store: store, videoId: "v", payload: Self.makePayload(size: 64))
        #expect(store.currentVideoId() == "v")
        store.clear()
        #expect(store.currentVideoId() == nil)
    }

    // MARK: - writeChunk

    @Test func writeChunk_withMismatchedVideoId_returnsFalse() {
        let store = CacheStore()
        store.setEntry(videoId: "v", totalSize: 1_000, contentType: "video/mp4", resumeByte: 0)
        let ok = store.writeChunk(videoId: "other", toRegion: .prefix, chunk: Data(repeating: 0, count: 100))
        #expect(ok == false)
        #expect(store.cachedByteCount(videoId: "v") == 0)
    }

    @Test func writeChunk_withNoEntry_returnsFalse() {
        let store = CacheStore()
        let ok = store.writeChunk(videoId: "v", toRegion: .prefix, chunk: Data(repeating: 0, count: 100))
        #expect(ok == false)
    }

    @Test func writeChunk_succeedsForMatchingEntry() {
        let store = CacheStore()
        store.setEntry(videoId: "v", totalSize: 1_000, contentType: "video/mp4", resumeByte: 0)
        let ok = store.writeChunk(videoId: "v", toRegion: .prefix, chunk: Data(repeating: 0xAB, count: 200))
        #expect(ok == true)
        #expect(store.cachedByteCount(videoId: "v") == 200)
    }

    // MARK: - setEntry

    @Test func setEntry_replacesExistingEntry() {
        let store = CacheStore()
        store.setEntry(videoId: "a", totalSize: 1_000, contentType: "video/mp4", resumeByte: 0)
        _ = store.writeChunk(videoId: "a", toRegion: .prefix, chunk: Data(repeating: 1, count: 100))
        #expect(store.cachedByteCount(videoId: "a") == 100)

        // Second entry: large totalSize so main exists; assert main status.
        let totalB: Int64 = 100 * 1024 * 1024
        let prefixB = CacheStore.computePrefixSize(totalSize: totalB)
        let resumeB = prefixB + 500
        store.setEntry(videoId: "b", totalSize: totalB, contentType: "video/webm", resumeByte: resumeB)
        #expect(store.cachedByteCount(videoId: "a") == 0)
        #expect(store.currentVideoId() == "b")
        let status = store.cacheStatus(videoId: "b")
        #expect(status?.startOffset == resumeB)
        #expect(status?.totalSize == totalB)
        #expect(status?.contentType == "video/webm")
    }

    // MARK: - trimFront

    @Test func trimFront_whenBelowMaxCacheSize_isNoOp() {
        let store = CacheStore()
        // Well below maxCacheSize (256MB) -> nothing to trim.
        Self.setEntryAndFill(store: store, videoId: "v", payload: Self.makePayload(size: 10 * 1024))
        // Set a playback offset that would otherwise be "trim eligible".
        store.updatePlaybackPosition(videoId: "v", seconds: 100, duration: 100)

        let removed = store.trimFront(videoId: "v")
        #expect(removed == 0)
        #expect(store.cachedByteCount(videoId: "v") == 10 * 1024)
    }

    @Test func trimFront_wrongVideoId_returnsZero() {
        let store = CacheStore()
        Self.setEntryAndFill(store: store, videoId: "v", payload: Self.makePayload(size: 1024))
        let removed = store.trimFront(videoId: "nope")
        #expect(removed == 0)
    }

    @Test func trimFront_noEntry_returnsZero() {
        let store = CacheStore()
        #expect(store.trimFront(videoId: "v") == 0)
    }

    // MARK: - emergencyTrim

    @Test func emergencyTrim_belowTarget_returnsZero() {
        // Use a multi-region setup so a `.main` region exists; emergencyTrim
        // is now a main-only operation. Seed below the target so the helper
        // is a no-op regardless of region layout.
        let store = CacheStore()
        let totalSize: Int64 = 100 * 1024 * 1024
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        Self.setEntryAndFill(
            store: store,
            videoId: "v",
            totalSize: totalSize,
            resumeByte: prefixSize,
            region: .main,
            payload: Self.makePayload(size: 2_000)
        )
        let removed = store.emergencyTrim(videoId: "v", targetSize: 10_000)
        #expect(removed == 0)
        #expect(store.cachedByteCount(videoId: "v") == 2_000)
    }

    @Test func emergencyTrim_aboveTarget_dropsChunksFromFront() {
        let store = CacheStore()
        // Use multi-region setup. 10 MB main + 8 MB prefix.
        let totalSize: Int64 = 100 * 1024 * 1024
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        store.setEntry(videoId: "v", totalSize: totalSize, contentType: "video/mp4", resumeByte: prefixSize)
        for i in 0..<10 {
            _ = store.writeChunk(videoId: "v", toRegion: .main, chunk: Data(repeating: UInt8(i), count: 1_024))
        }
        // cachedByteCount sums BOTH regions; only main has data here.
        #expect(store.cachedByteCount(videoId: "v") == 10 * 1_024)

        // Target 5 KB — should drop ~5 chunks from front (overflow=5120, whole chunks only).
        let removed = store.emergencyTrim(videoId: "v", targetSize: 5 * 1_024)
        #expect(removed >= 5 * 1_024)
        #expect(store.cachedByteCount(videoId: "v") <= 5 * 1_024)
        // main.startOffset advances by `removed` so reads start at the new boundary.
        let status = store.cacheStatus(videoId: "v")
        #expect(status?.startOffset == prefixSize + Int64(removed))
    }

    @Test func emergencyTrim_wrongVideoId_returnsZero() {
        let store = CacheStore()
        Self.setEntryAndFill(store: store, videoId: "v", payload: Self.makePayload(size: 10_000))
        let removed = store.emergencyTrim(videoId: "nope", targetSize: 0)
        #expect(removed == 0)
        #expect(store.cachedByteCount(videoId: "v") == 10_000)
    }

    // MARK: - clear

    @Test func clear_emptiesEverything() {
        let store = CacheStore()
        Self.setEntryAndFill(store: store, videoId: "v", payload: Self.makePayload(size: 1024))
        // Small payload → only prefix exists; cacheStatus returns nil already
        // because there's no `.main`. Use `regionStatus` to assert the entry
        // is real before the clear.
        #expect(store.regionStatus(videoId: "v", region: .prefix) != nil)
        store.clear()
        #expect(store.regionStatus(videoId: "v", region: .prefix) == nil)
        #expect(store.cacheStatus(videoId: "v") == nil)
        #expect(store.cachedByteCount(videoId: "v") == 0)
        #expect(store.currentVideoId() == nil)
        #expect(store.readData(videoId: "v", offset: 0, length: 16) == nil)
    }

    // MARK: - updatePlaybackPosition

    @Test func updatePlaybackPosition_isNoOpWithoutEntry() {
        let store = CacheStore()
        // Just verify no crash and subsequent operations succeed.
        store.updatePlaybackPosition(videoId: "v", seconds: 10, duration: 60)
        #expect(store.cacheStatus(videoId: "v") == nil)
    }

    @Test func updatePlaybackPosition_isNoOpForZeroDuration() {
        let store = CacheStore()
        Self.setEntryAndFill(store: store, videoId: "v", payload: Self.makePayload(size: 1024))
        store.updatePlaybackPosition(videoId: "v", seconds: 10, duration: 0)
        // No crash; reads still work.
        #expect(store.readData(videoId: "v", offset: 0, length: 16)?.count == 16)
    }

    // MARK: - Task 2: Multi-region tests

    /// Convenience: seed both regions with distinct payloads in a single call.
    private static func seedBothRegions(
        store: CacheStore,
        videoId: String,
        totalSize: Int64,
        resumeByte: Int64,
        prefixPayload: Data,
        mainPayload: Data
    ) {
        store.setEntry(
            videoId: videoId,
            totalSize: totalSize,
            contentType: "video/mp4",
            resumeByte: resumeByte
        )
        var offset = 0
        while offset < prefixPayload.count {
            let end = min(offset + CacheStore.chunkSize, prefixPayload.count)
            _ = store.writeChunk(videoId: videoId, toRegion: .prefix, chunk: Data(prefixPayload[offset..<end]))
            offset = end
        }
        offset = 0
        while offset < mainPayload.count {
            let end = min(offset + CacheStore.chunkSize, mainPayload.count)
            _ = store.writeChunk(videoId: videoId, toRegion: .main, chunk: Data(mainPayload[offset..<end]))
            offset = end
        }
    }

    @Test func readData_hitsPrefixRegion() {
        let store = CacheStore()
        let totalSize: Int64 = 100 * 1024 * 1024
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        let resumeByte = prefixSize + 1024
        let prefixPayload = Data(repeating: 0xAA, count: 4 * 1024)   // 4 KB into prefix
        let mainPayload = Data(repeating: 0xBB, count: 4 * 1024)
        Self.seedBothRegions(
            store: store,
            videoId: "v",
            totalSize: totalSize,
            resumeByte: resumeByte,
            prefixPayload: prefixPayload,
            mainPayload: mainPayload
        )

        // Offset 256 falls inside prefix. Returned bytes must be 0xAA.
        let slice = store.readData(videoId: "v", offset: 256, length: 128)
        #expect(slice?.count == 128)
        #expect(slice?.first == 0xAA)
        #expect(slice?.last == 0xAA)
    }

    @Test func readData_hitsMainRegion() {
        let store = CacheStore()
        let totalSize: Int64 = 100 * 1024 * 1024
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        let resumeByte = prefixSize + 1024
        let prefixPayload = Data(repeating: 0xAA, count: 4 * 1024)
        let mainPayload = Data(repeating: 0xBB, count: 4 * 1024)
        Self.seedBothRegions(
            store: store,
            videoId: "v",
            totalSize: totalSize,
            resumeByte: resumeByte,
            prefixPayload: prefixPayload,
            mainPayload: mainPayload
        )

        // Offset = main.startOffset + 256 → returns 0xBB.
        let slice = store.readData(videoId: "v", offset: resumeByte + 256, length: 128)
        #expect(slice?.count == 128)
        #expect(slice?.first == 0xBB)
    }

    @Test func readData_crossesBoundary_returnsPartial() {
        // A request that straddles prefix→main boundary returns only the bytes
        // from the matched (prefix) region; AVPlayer issues a follow-up request
        // for the rest.
        let store = CacheStore()
        let totalSize: Int64 = 100 * 1024 * 1024
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        let resumeByte = prefixSize  // main starts immediately after prefix
        // Fill prefix completely (8 MB) so prefix.endOffset == prefixSize.
        let prefixPayload = Data(repeating: 0xAA, count: Int(prefixSize))
        let mainPayload = Data(repeating: 0xBB, count: 4 * 1024)
        Self.seedBothRegions(
            store: store,
            videoId: "v",
            totalSize: totalSize,
            resumeByte: resumeByte,
            prefixPayload: prefixPayload,
            mainPayload: mainPayload
        )

        // Request the last 1 KB of prefix + 1 KB into main: should return only
        // the 1 KB of prefix (0xAA), not 2 KB.
        let offset = prefixSize - 1024
        let slice = store.readData(videoId: "v", offset: offset, length: 2048)
        #expect(slice?.count == 1024)
        #expect(slice?.first == 0xAA)
        #expect(slice?.last == 0xAA)
    }

    @Test func readData_uncoveredOffset_returnsNil() {
        // Offset between prefix.endOffset (no chunks written so prefix end = 0)
        // and main.startOffset; or beyond main.endOffset.
        let store = CacheStore()
        let totalSize: Int64 = 100 * 1024 * 1024
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        let resumeByte = prefixSize + 10_000
        store.setEntry(videoId: "v", totalSize: totalSize, contentType: "video/mp4", resumeByte: resumeByte)
        // Write only 1 KB into prefix and 1 KB into main.
        _ = store.writeChunk(videoId: "v", toRegion: .prefix, chunk: Data(repeating: 0xAA, count: 1024))
        _ = store.writeChunk(videoId: "v", toRegion: .main, chunk: Data(repeating: 0xBB, count: 1024))

        // Between prefix.endOffset (1024) and main.startOffset (resumeByte): nil.
        #expect(store.readData(videoId: "v", offset: 5_000, length: 16) == nil)
        // Beyond main.endOffset: nil.
        #expect(store.readData(videoId: "v", offset: resumeByte + 1024, length: 16) == nil)
    }

    @Test func writeChunk_toPrefix_independentFromMain() async {
        // Concurrent writes to the two distinct regions must not corrupt each
        // other. Run a small parallel race and verify the byte counts and a
        // sample read from each region.
        let store = CacheStore()
        let totalSize: Int64 = 100 * 1024 * 1024
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        store.setEntry(videoId: "v", totalSize: totalSize, contentType: "video/mp4", resumeByte: prefixSize)

        let iterations = 100
        let chunkBytes = 1024
        async let prefixWrites: Void = Task.detached {
            for _ in 0..<iterations {
                _ = store.writeChunk(videoId: "v", toRegion: .prefix, chunk: Data(repeating: 0xAA, count: chunkBytes))
            }
        }.value
        async let mainWrites: Void = Task.detached {
            for _ in 0..<iterations {
                _ = store.writeChunk(videoId: "v", toRegion: .main, chunk: Data(repeating: 0xBB, count: chunkBytes))
            }
        }.value
        _ = await (prefixWrites, mainWrites)

        let prefixStatus = store.regionStatus(videoId: "v", region: .prefix)
        let mainStatus = store.regionStatus(videoId: "v", region: .main)
        #expect(prefixStatus?.endOffset == Int64(iterations * chunkBytes))
        #expect(mainStatus?.startOffset == prefixSize)
        #expect(mainStatus?.endOffset == prefixSize + Int64(iterations * chunkBytes))
        // Sample reads into each region must return the correct byte values.
        #expect(store.readData(videoId: "v", offset: 100, length: 1)?.first == 0xAA)
        #expect(store.readData(videoId: "v", offset: prefixSize + 100, length: 1)?.first == 0xBB)
    }

    @Test func writeChunk_wrongRegionRejected() {
        // Small file: only `.prefix` exists. Writing to `.main` must return
        // false and not mutate the entry.
        let store = CacheStore()
        store.setEntry(videoId: "v", totalSize: 4096, contentType: "video/mp4", resumeByte: 0)
        let ok = store.writeChunk(videoId: "v", toRegion: .main, chunk: Data(repeating: 0xCC, count: 100))
        #expect(ok == false)
        #expect(store.cachedByteCount(videoId: "v") == 0)
        #expect(store.regionStatus(videoId: "v", region: .main) == nil)
    }

    @Test func trimFront_onlyAffectsMain_prefixPreserved() {
        // Seed enough main bytes that trimFront has work to do, plus some
        // prefix bytes. Move playback past the behindMargin and assert main
        // shrinks while prefix is untouched.
        let store = CacheStore()
        // Use a tiny totalSize / duration combination to keep the test fast.
        // Approach: directly invoke trimFront with a controlled playback
        // offset by abusing updatePlaybackPosition's `seconds * avgByterate`.
        // Total = trimThreshold + some buffer; main will be > maxCacheSize.
        let mainBytes = CacheStore.trimThreshold + (32 * 1024 * 1024)
        let totalSize: Int64 = Int64(mainBytes) + 100 * 1024 * 1024
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        let resumeByte = prefixSize
        store.setEntry(videoId: "v", totalSize: totalSize, contentType: "video/mp4", resumeByte: resumeByte)
        // 4 chunks of prefix data (2 MB).
        for _ in 0..<4 {
            _ = store.writeChunk(videoId: "v", toRegion: .prefix, chunk: Data(repeating: 0xAA, count: CacheStore.chunkSize))
        }
        // Fill main with `mainBytes`.
        var written = 0
        let mainChunk = Data(repeating: 0xBB, count: CacheStore.chunkSize)
        while written < mainBytes {
            _ = store.writeChunk(videoId: "v", toRegion: .main, chunk: mainChunk)
            written += mainChunk.count
        }

        // Position playback far enough ahead in main that the trim path
        // considers most of the front trimmable.
        let playbackByte = resumeByte + Int64(mainBytes - 50_000_000)
        // Compute seconds such that updatePlaybackPosition produces ~playbackByte.
        let duration: Double = 1000
        let avgByterate = Double(totalSize) / duration
        let seconds = Double(playbackByte) / avgByterate
        store.updatePlaybackPosition(videoId: "v", seconds: seconds, duration: duration)

        let prefixBytesBefore = store.regionStatus(videoId: "v", region: .prefix)
        let mainBytesBefore = store.regionStatus(videoId: "v", region: .main)

        let removed = store.trimFront(videoId: "v")
        #expect(removed > 0)

        let prefixBytesAfter = store.regionStatus(videoId: "v", region: .prefix)
        let mainBytesAfter = store.regionStatus(videoId: "v", region: .main)
        // Prefix unchanged.
        #expect(prefixBytesAfter?.startOffset == prefixBytesBefore?.startOffset)
        #expect(prefixBytesAfter?.endOffset == prefixBytesBefore?.endOffset)
        // Main advanced (front trimmed).
        #expect((mainBytesAfter?.startOffset ?? 0) > (mainBytesBefore?.startOffset ?? 0))
    }

    // MARK: - Promote-on-trim (prefix grows from trimmed main bytes)

    /// Fill prefix region with exactly `size` bytes — last chunk is partial
    /// so prefix.endOffset == size exactly (matches production downloadRange
    /// behavior where HTTP Range returns exactly the requested bytes).
    private func fillPrefixExactly(_ store: CacheStore, videoId: String, size: Int64, byte: UInt8 = 0xAA) {
        var written: Int64 = 0
        let fullChunk = Data(repeating: byte, count: CacheStore.chunkSize)
        while written + Int64(CacheStore.chunkSize) <= size {
            _ = store.writeChunk(videoId: videoId, toRegion: .prefix, chunk: fullChunk)
            written += Int64(CacheStore.chunkSize)
        }
        if written < size {
            let partial = Data(repeating: byte, count: Int(size - written))
            _ = store.writeChunk(videoId: videoId, toRegion: .prefix, chunk: partial)
        }
    }

    /// Seeds an entry where prefix is FULLY populated (covers [0, prefixSize))
    /// and main starts at prefixSize (resume <= prefixSize). Trimming main
    /// should move trimmed chunks to prefix's tail, growing prefix and keeping
    /// the regions adjacent (no gap).
    @Test func trimFront_whenPrefixAdjacent_promotesToPrefix() {
        let store = CacheStore()
        let mainBytes = CacheStore.trimThreshold + (32 * 1024 * 1024)
        let totalSize: Int64 = Int64(mainBytes) + 200 * 1024 * 1024
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        store.setEntry(videoId: "v", totalSize: totalSize, contentType: "video/mp4", resumeByte: 0)
        // Fill prefix to EXACTLY prefixSize (last chunk partial if needed) so
        // prefix.endOffset == main.startOffset (adjacency precondition for promote).
        fillPrefixExactly(store, videoId: "v", size: prefixSize)
        // Fill main past trim threshold.
        var mainWritten = 0
        let mainChunk = Data(repeating: 0xBB, count: CacheStore.chunkSize)
        while mainWritten < mainBytes {
            _ = store.writeChunk(videoId: "v", toRegion: .main, chunk: mainChunk)
            mainWritten += mainChunk.count
        }
        // Advance playback past behindMargin so trim can proceed.
        let duration: Double = 1000
        let avgByterate = Double(totalSize) / duration
        let playbackByte = prefixSize + Int64(mainBytes - 50_000_000)
        let seconds = Double(playbackByte) / avgByterate
        store.updatePlaybackPosition(videoId: "v", seconds: seconds, duration: duration)

        let prefixBefore = store.regionStatus(videoId: "v", region: .prefix)
        let mainBefore = store.regionStatus(videoId: "v", region: .main)
        #expect(prefixBefore?.endOffset == mainBefore?.startOffset) // adjacency precondition

        let removed = store.trimFront(videoId: "v")
        #expect(removed > 0)

        let prefixAfter = store.regionStatus(videoId: "v", region: .prefix)
        let mainAfter = store.regionStatus(videoId: "v", region: .main)
        // Prefix endOffset advanced by exactly the promoted bytes.
        #expect((prefixAfter?.endOffset ?? 0) > (prefixBefore?.endOffset ?? 0))
        // Main startOffset advanced by the same amount.
        #expect(prefixAfter?.endOffset == mainAfter?.startOffset) // still adjacent
    }

    /// When prefix is at the soft cap (maxPrefixSize), promoting more bytes
    /// would exceed it. Trimmed bytes are discarded as before; main shrinks,
    /// prefix unchanged.
    @Test func trimFront_whenPrefixAtSoftCap_discardsTrimmedBytes() {
        let store = CacheStore()
        // Use a large totalSize so we can fill prefix to the cap.
        let totalSize: Int64 = 10_000_000_000
        // prefixSize = clamp(totalSize * 0.01, 8MB, 50MB) = 50MB (ceiling)
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        #expect(prefixSize == 50_000_000)
        store.setEntry(videoId: "v", totalSize: totalSize, contentType: "video/mp4", resumeByte: 0)
        // Fill prefix to EXACTLY the soft cap (simulates prefix already grown
        // via earlier promotes). Adjacency check uses prefix.endOffset, so we
        // need it to land exactly on the boundary that main will sit at.
        fillPrefixExactly(store, videoId: "v", size: Int64(CacheStore.prefixGrowthCap))
        var prefixWritten = Int64(CacheStore.prefixGrowthCap)
        let chunk = Data(repeating: 0xAA, count: CacheStore.chunkSize)
        // (no-op placeholder so the rest of the test reads the same)
        _ = (prefixWritten, chunk)
        // Fill main past trim threshold.
        var mainWritten = 0
        let mainChunk = Data(repeating: 0xBB, count: CacheStore.chunkSize)
        let mainBytes = CacheStore.trimThreshold + (32 * 1024 * 1024)
        while mainWritten < mainBytes {
            _ = store.writeChunk(videoId: "v", toRegion: .main, chunk: mainChunk)
            mainWritten += mainChunk.count
        }
        let duration: Double = 5000
        let avgByterate = Double(totalSize) / duration
        let playbackByte = prefixWritten + Int64(mainBytes - 50_000_000)
        let seconds = Double(playbackByte) / avgByterate
        store.updatePlaybackPosition(videoId: "v", seconds: seconds, duration: duration)

        let prefixBefore = store.regionStatus(videoId: "v", region: .prefix)!
        let removed = store.trimFront(videoId: "v")
        #expect(removed > 0)
        let prefixAfter = store.regionStatus(videoId: "v", region: .prefix)!
        // Prefix at cap → no promote → endOffset unchanged.
        #expect(prefixAfter.endOffset == prefixBefore.endOffset)
    }

    /// When prefix is NOT adjacent to main (resume far from start), trim of
    /// main cannot bridge into prefix without creating a disjoint region.
    /// Trimmed bytes must be discarded.
    @Test func trimFront_whenPrefixNotAdjacent_discardsTrimmedBytes() {
        let store = CacheStore()
        let mainBytes = CacheStore.trimThreshold + (32 * 1024 * 1024)
        let totalSize: Int64 = Int64(mainBytes) + 500 * 1024 * 1024
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        // Resume FAR past prefix end — initial gap between prefix and main.
        let resumeByte: Int64 = prefixSize + 100_000_000
        store.setEntry(videoId: "v", totalSize: totalSize, contentType: "video/mp4", resumeByte: resumeByte)
        // Fully populate prefix.
        var prefixWritten: Int64 = 0
        let prefixChunk = Data(repeating: 0xAA, count: CacheStore.chunkSize)
        while prefixWritten < prefixSize {
            _ = store.writeChunk(videoId: "v", toRegion: .prefix, chunk: prefixChunk)
            prefixWritten += Int64(prefixChunk.count)
        }
        // Fill main.
        var mainWritten = 0
        let mainChunk = Data(repeating: 0xBB, count: CacheStore.chunkSize)
        while mainWritten < mainBytes {
            _ = store.writeChunk(videoId: "v", toRegion: .main, chunk: mainChunk)
            mainWritten += mainChunk.count
        }
        let duration: Double = 2000
        let avgByterate = Double(totalSize) / duration
        let playbackByte = resumeByte + Int64(mainBytes - 50_000_000)
        let seconds = Double(playbackByte) / avgByterate
        store.updatePlaybackPosition(videoId: "v", seconds: seconds, duration: duration)

        let prefixBefore = store.regionStatus(videoId: "v", region: .prefix)!
        let mainBefore = store.regionStatus(videoId: "v", region: .main)!
        #expect(prefixBefore.endOffset != mainBefore.startOffset) // gap exists

        let removed = store.trimFront(videoId: "v")
        #expect(removed > 0)
        let prefixAfter = store.regionStatus(videoId: "v", region: .prefix)!
        // Prefix unchanged because main is not adjacent.
        #expect(prefixAfter.endOffset == prefixBefore.endOffset)
    }

    /// Boundary: prefix has headroom for SOME but not all trimmed chunks.
    /// Partial promote — prefix grows to prefixGrowthCap, remainder discarded.
    @Test func trimFront_whenPrefixPartialHeadroom_partialPromote() {
        let store = CacheStore()
        let totalSize: Int64 = 10_000_000_000
        // Strategy: use resumeByte to force main.startOffset close to prefixGrowthCap,
        // then fill prefix from byte 0 up to exactly main.startOffset. This simulates
        // the state where many earlier promotes have already grown prefix to near-cap.
        // Leave a 10-chunk headroom (~5MB) below the cap.
        let headroomBytes: Int64 = 10 * Int64(CacheStore.chunkSize)
        let resumeByte: Int64 = Int64(CacheStore.prefixGrowthCap) - headroomBytes
        store.setEntry(videoId: "v", totalSize: totalSize, contentType: "video/mp4", resumeByte: resumeByte)
        // Confirm main starts at resumeByte (resumeByte > prefixSize).
        #expect(store.regionStatus(videoId: "v", region: .main)?.startOffset == resumeByte)
        // Fill prefix exactly up to main.startOffset for adjacency.
        fillPrefixExactly(store, videoId: "v", size: resumeByte)

        // Fill main past trim threshold so trim will want to remove many chunks
        // (~282MB). Only ~5MB fits in remaining prefix headroom.
        var mainWritten = 0
        let mainChunk = Data(repeating: 0xBB, count: CacheStore.chunkSize)
        let mainBytes = CacheStore.trimThreshold + (32 * 1024 * 1024)
        while mainWritten < mainBytes {
            _ = store.writeChunk(videoId: "v", toRegion: .main, chunk: mainChunk)
            mainWritten += mainChunk.count
        }
        let duration: Double = 5000
        let avgByterate = Double(totalSize) / duration
        let playbackByte = resumeByte + Int64(mainBytes - 50_000_000)
        let seconds = Double(playbackByte) / avgByterate
        store.updatePlaybackPosition(videoId: "v", seconds: seconds, duration: duration)

        let prefixBefore = store.regionStatus(videoId: "v", region: .prefix)!
        #expect(prefixBefore.endOffset == resumeByte) // adjacency precondition
        let removed = store.trimFront(videoId: "v")
        #expect(removed > 0)
        let prefixAfter = store.regionStatus(videoId: "v", region: .prefix)!
        // Prefix grew but not by the full trim amount (capped at prefixGrowthCap).
        #expect(prefixAfter.endOffset > prefixBefore.endOffset)
        let prefixGrowth = prefixAfter.endOffset - prefixBefore.endOffset
        #expect(prefixGrowth <= headroomBytes)
        #expect(prefixGrowth < Int64(removed)) // partial — some bytes were discarded
    }

    /// After promote, readData at offsets in the newly-promoted byte range
    /// must succeed from prefix.
    @Test func readData_afterPromote_servesPromotedBytes() {
        let store = CacheStore()
        let mainBytes = CacheStore.trimThreshold + (32 * 1024 * 1024)
        let totalSize: Int64 = Int64(mainBytes) + 200 * 1024 * 1024
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        store.setEntry(videoId: "v", totalSize: totalSize, contentType: "video/mp4", resumeByte: 0)
        // Fully populate prefix to EXACTLY prefixSize (adjacency).
        fillPrefixExactly(store, videoId: "v", size: prefixSize)
        // Fill main with a distinguishable byte pattern in its first chunk so
        // we can verify which region served the read after promote.
        let firstMainChunk = Data(repeating: 0xCC, count: CacheStore.chunkSize)
        _ = store.writeChunk(videoId: "v", toRegion: .main, chunk: firstMainChunk)
        let regularMainChunk = Data(repeating: 0xBB, count: CacheStore.chunkSize)
        var mainWritten = firstMainChunk.count
        while mainWritten < mainBytes {
            _ = store.writeChunk(videoId: "v", toRegion: .main, chunk: regularMainChunk)
            mainWritten += regularMainChunk.count
        }
        // Read byte at main.startOffset BEFORE trim — should be 0xCC.
        let mainStartBefore = store.regionStatus(videoId: "v", region: .main)!.startOffset
        let dataBefore = store.readData(videoId: "v", offset: mainStartBefore, length: 1)
        #expect(dataBefore?.first == 0xCC)

        // Advance playback so trim is allowed.
        let duration: Double = 1000
        let avgByterate = Double(totalSize) / duration
        let playbackByte = prefixSize + Int64(mainBytes - 50_000_000)
        let seconds = Double(playbackByte) / avgByterate
        store.updatePlaybackPosition(videoId: "v", seconds: seconds, duration: duration)
        _ = store.trimFront(videoId: "v")

        // After trim, byte at the OLD main.startOffset must still be 0xCC —
        // it's been promoted into prefix.
        let dataAfter = store.readData(videoId: "v", offset: mainStartBefore, length: 1)
        #expect(dataAfter?.first == 0xCC)
        // And it must come from prefix region (main has advanced past).
        let mainStartAfter = store.regionStatus(videoId: "v", region: .main)!.startOffset
        #expect(mainStartAfter > mainStartBefore)
        let prefixEndAfter = store.regionStatus(videoId: "v", region: .prefix)!.endOffset
        #expect(prefixEndAfter > mainStartBefore) // promoted byte now lives in prefix
    }

    @Test func emergencyTrim_preservesPrefix() {
        // emergencyTrim must shrink only `.main`. Prefix bytes survive intact.
        let store = CacheStore()
        let totalSize: Int64 = 100 * 1024 * 1024
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        let resumeByte = prefixSize
        store.setEntry(videoId: "v", totalSize: totalSize, contentType: "video/mp4", resumeByte: resumeByte)
        // 4 KB of prefix.
        _ = store.writeChunk(videoId: "v", toRegion: .prefix, chunk: Data(repeating: 0xAA, count: 4 * 1024))
        // 10 KB across 10 chunks of main.
        for i in 0..<10 {
            _ = store.writeChunk(videoId: "v", toRegion: .main, chunk: Data(repeating: UInt8(i), count: 1024))
        }

        let prefixBefore = store.regionStatus(videoId: "v", region: .prefix)
        let mainBefore = store.regionStatus(videoId: "v", region: .main)
        let removed = store.emergencyTrim(videoId: "v", targetSize: 5 * 1024)
        #expect(removed >= 5 * 1024)

        let prefixAfter = store.regionStatus(videoId: "v", region: .prefix)
        let mainAfter = store.regionStatus(videoId: "v", region: .main)
        #expect(prefixAfter?.startOffset == prefixBefore?.startOffset)
        #expect(prefixAfter?.endOffset == prefixBefore?.endOffset)
        // Main advanced (chunks dropped from front).
        #expect((mainAfter?.startOffset ?? 0) > (mainBefore?.startOffset ?? 0))
        // Prefix data still readable.
        #expect(store.readData(videoId: "v", offset: 100, length: 16)?.first == 0xAA)
    }

    @Test func clear_clearsBothRegions() {
        let store = CacheStore()
        let totalSize: Int64 = 100 * 1024 * 1024
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        store.setEntry(videoId: "v", totalSize: totalSize, contentType: "video/mp4", resumeByte: prefixSize)
        _ = store.writeChunk(videoId: "v", toRegion: .prefix, chunk: Data(repeating: 0xAA, count: 1024))
        _ = store.writeChunk(videoId: "v", toRegion: .main, chunk: Data(repeating: 0xBB, count: 1024))

        #expect(store.regionStatus(videoId: "v", region: .prefix) != nil)
        #expect(store.regionStatus(videoId: "v", region: .main) != nil)
        store.clear()
        #expect(store.regionStatus(videoId: "v", region: .prefix) == nil)
        #expect(store.regionStatus(videoId: "v", region: .main) == nil)
        #expect(store.currentVideoId() == nil)
    }

    // Note: a near-duplicate of `cacheStatus_returnsMainStatus_whenMainExists`
    // (see above) previously lived here. Removed during review phase 1; the
    // single test above covers the same contract.

    @Test func cacheStatus_returnsNilWhenOnlyPrefix() {
        // Small file → only prefix region; cacheStatus returns nil so callers
        // don't accidentally treat prefix as main.
        let store = CacheStore()
        store.setEntry(videoId: "v", totalSize: 4096, contentType: "video/mp4", resumeByte: 0)
        _ = store.writeChunk(videoId: "v", toRegion: .prefix, chunk: Data(repeating: 0xAA, count: 1024))
        #expect(store.cacheStatus(videoId: "v") == nil)
        // But prefix is observable via regionStatus.
        #expect(store.regionStatus(videoId: "v", region: .prefix)?.endOffset == 1024)
    }

    @Test func regionStatus_returnsCorrectRegion() {
        let store = CacheStore()
        let totalSize: Int64 = 100 * 1024 * 1024
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        let resumeByte = prefixSize + 1234
        store.setEntry(videoId: "v", totalSize: totalSize, contentType: "video/mp4", resumeByte: resumeByte)
        _ = store.writeChunk(videoId: "v", toRegion: .prefix, chunk: Data(repeating: 0xAA, count: 100))
        _ = store.writeChunk(videoId: "v", toRegion: .main, chunk: Data(repeating: 0xBB, count: 200))

        let prefixStatus = store.regionStatus(videoId: "v", region: .prefix)
        #expect(prefixStatus?.startOffset == 0)
        #expect(prefixStatus?.endOffset == 100)
        #expect(prefixStatus?.totalSize == totalSize)

        let mainStatus = store.regionStatus(videoId: "v", region: .main)
        #expect(mainStatus?.startOffset == resumeByte)
        #expect(mainStatus?.endOffset == resumeByte + 200)
        #expect(mainStatus?.totalSize == totalSize)

        // Wrong videoId → nil for either region.
        #expect(store.regionStatus(videoId: "other", region: .prefix) == nil)
        #expect(store.regionStatus(videoId: "other", region: .main) == nil)
    }

    @Test func cachedByteCount_sumsBothRegions() {
        let store = CacheStore()
        let totalSize: Int64 = 100 * 1024 * 1024
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        store.setEntry(videoId: "v", totalSize: totalSize, contentType: "video/mp4", resumeByte: prefixSize)
        _ = store.writeChunk(videoId: "v", toRegion: .prefix, chunk: Data(repeating: 0xAA, count: 100))
        _ = store.writeChunk(videoId: "v", toRegion: .main, chunk: Data(repeating: 0xBB, count: 200))
        #expect(store.cachedByteCount(videoId: "v") == 300)
    }

    @Test func setEntry_smallVideo_onlyPrefixCreated() {
        // totalSize <= prefixSize → only `.prefix` is created.
        let store = CacheStore()
        store.setEntry(videoId: "v", totalSize: 4096, contentType: "video/mp4", resumeByte: 0)
        #expect(store.regionStatus(videoId: "v", region: .prefix) != nil)
        #expect(store.regionStatus(videoId: "v", region: .main) == nil)
        // cacheStatus is main-only → returns nil for small-file case.
        #expect(store.cacheStatus(videoId: "v") == nil)
    }

    @Test func setEntry_totalSizeEqualsPrefixSize_boundaryCase() {
        // At the boundary: totalSize == prefixSize → only `.prefix` is created
        // (the condition is `totalSize > prefixSize` for main creation).
        let store = CacheStore()
        // Use a totalSize that produces a deterministic prefixSize. Since the
        // formula clamps to `minPrefixSize` (8 MB) for totalSize <= 800 MB,
        // pick exactly minPrefixSize for the boundary.
        let totalSize = CacheStore.minPrefixSize
        store.setEntry(videoId: "v", totalSize: totalSize, contentType: "video/mp4", resumeByte: 0)
        #expect(store.regionStatus(videoId: "v", region: .prefix) != nil)
        #expect(store.regionStatus(videoId: "v", region: .main) == nil)
    }

    // MARK: - Boundary tests (review phase 1)

    @Test func readData_atMainStartOffset_returnsFirstMainByte() {
        // Reading at exactly `main.startOffset` must return the first byte of
        // the main region, not nil. Off-by-one regressions in
        // `regionForLocked` / `readData` would surface here.
        let store = CacheStore()
        let totalSize: Int64 = 100 * 1024 * 1024
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        let resumeByte = prefixSize + 4096
        let payload = Self.makePayload(size: 8 * 1024)
        Self.setEntryAndFill(
            store: store,
            videoId: "v",
            totalSize: totalSize,
            resumeByte: resumeByte,
            region: .main,
            payload: payload
        )
        let slice = store.readData(videoId: "v", offset: resumeByte, length: 1)
        #expect(slice?.count == 1)
        #expect(slice == payload.prefix(1))
    }

    @Test func readData_atPrefixEndOffsetMinusOne_returnsLastPrefixByte() {
        // Last byte of the prefix region must be readable. `endOffset` is
        // exclusive, so `endOffset - 1` is the last valid offset.
        let store = CacheStore()
        let totalSize: Int64 = 100 * 1024 * 1024
        let payloadSize = 4096
        let payload = Self.makePayload(size: payloadSize)
        store.setEntry(
            videoId: "v",
            totalSize: totalSize,
            contentType: "video/mp4",
            resumeByte: 0
        )
        _ = store.writeChunk(videoId: "v", toRegion: .prefix, chunk: payload)
        let prefixEnd = store.regionStatus(videoId: "v", region: .prefix)!.endOffset
        let slice = store.readData(videoId: "v", offset: prefixEnd - 1, length: 1)
        #expect(slice?.count == 1)
        #expect(slice == payload.suffix(1))
    }

    @Test func setEntry_sameVideoId_differentTotalSize_replacesRegionsAndResetsPlayback() {
        // Re-`setEntry` for the same videoId with a DIFFERENT totalSize
        // (e.g. server returned a re-encoded smaller variant) must replace
        // the regions entirely (old chunks gone) and reset the
        // playback-position tracker. The same-(videoId, totalSize,
        // contentType) idempotency path (see
        // `setEntry_idempotent_whenSameVideoIdTotalSizeContentType_preservesRegions`)
        // does NOT apply here because `totalSize` differs.
        let store = CacheStore()
        let totalSize: Int64 = 200 * 1024 * 1024
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        store.setEntry(
            videoId: "v",
            totalSize: totalSize,
            contentType: "video/mp4",
            resumeByte: prefixSize
        )
        _ = store.writeChunk(videoId: "v", toRegion: .prefix, chunk: Data(repeating: 0xAA, count: 1024))
        _ = store.writeChunk(videoId: "v", toRegion: .main, chunk: Data(repeating: 0xBB, count: 1024))
        store.updatePlaybackPosition(videoId: "v", seconds: 5, duration: 100)
        #expect(store.cachedByteCount(videoId: "v") == 2048)

        // Replace with a new entry — different totalSize, different resume.
        let newTotalSize: Int64 = 300 * 1024 * 1024
        let newPrefixSize = CacheStore.computePrefixSize(totalSize: newTotalSize)
        let newResumeByte = newPrefixSize + 9999
        store.setEntry(
            videoId: "v",
            totalSize: newTotalSize,
            contentType: "video/mp4",
            resumeByte: newResumeByte
        )

        // Both regions must be empty (chunks dropped).
        #expect(store.cachedByteCount(videoId: "v") == 0)
        let prefixStatus = store.regionStatus(videoId: "v", region: .prefix)
        #expect(prefixStatus?.endOffset == 0)
        let mainStatus = store.regionStatus(videoId: "v", region: .main)
        #expect(mainStatus?.startOffset == newResumeByte)
        #expect(mainStatus?.endOffset == newResumeByte)

        // Playback offset reset → trim has no margin → `trimFront` returns 0.
        // We can't read `lastPlaybackOffset` directly, but its observable
        // effect through `trimFront` confirms the reset.
        #expect(store.trimFront(videoId: "v") == 0)
    }

    /// Same-(videoId, totalSize, contentType) `setEntry` calls are
    /// idempotent: regions, chunks, and `lastPlaybackOffset` survive. This
    /// is load-bearing for the `.critical` → `restartPreloadIfNeeded` →
    /// `startPreloadWithRetry` → `downloadVideo` chain — the restart hook
    /// calls `resetMainRegion` to re-anchor `.main` at the new playhead
    /// while preserving `.prefix`, then `downloadVideo` re-calls `setEntry`
    /// with identical params from the HEAD probe. Without idempotency, the
    /// `.prefix` bytes the soft-`.critical` policy preserved would be
    /// wiped, opening a moov-cache-miss window where scrub-after-resume
    /// can re-trigger the freeze the two-region architecture exists to
    /// prevent.
    @Test func setEntry_idempotent_whenSameVideoIdTotalSizeContentType_preservesRegions() {
        let store = CacheStore()
        let totalSize: Int64 = 200 * 1024 * 1024 // 200 MB → both regions
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        let resumeByte = prefixSize
        store.setEntry(
            videoId: "v",
            totalSize: totalSize,
            contentType: "video/mp4",
            resumeByte: resumeByte
        )
        _ = store.writeChunk(videoId: "v", toRegion: .prefix, chunk: Data(repeating: 0xAA, count: 8 * 1024 * 1024))
        _ = store.writeChunk(videoId: "v", toRegion: .main, chunk: Data(repeating: 0xBB, count: 50 * 1024 * 1024))
        // Set lastPlaybackOffset to a known value so we can confirm it survived.
        let duration: Double = 100
        store.updatePlaybackPosition(videoId: "v", seconds: 50, duration: duration)
        let playbackOffsetBefore = store.testInspectLastPlaybackOffset()
        #expect(playbackOffsetBefore > 0, "precondition: playback offset must be set")

        let prefixBefore = store.regionStatus(videoId: "v", region: .prefix)!
        let mainBefore = store.regionStatus(videoId: "v", region: .main)!
        let cachedBefore = store.cachedByteCount(videoId: "v")
        #expect(prefixBefore.endOffset > 0, "precondition: prefix must be populated")
        #expect(mainBefore.endOffset > mainBefore.startOffset, "precondition: main must be populated")
        #expect(cachedBefore > 0)

        // Same-(videoId, totalSize, contentType) re-call. Even with a
        // DIFFERENT resumeByte, this MUST be a no-op — the caller is
        // expected to use `resetMainRegion` for anchor changes.
        store.setEntry(
            videoId: "v",
            totalSize: totalSize,
            contentType: "video/mp4",
            resumeByte: resumeByte + 5_000_000
        )

        let prefixAfter = store.regionStatus(videoId: "v", region: .prefix)!
        let mainAfter = store.regionStatus(videoId: "v", region: .main)!
        let cachedAfter = store.cachedByteCount(videoId: "v")

        #expect(prefixAfter.startOffset == prefixBefore.startOffset)
        #expect(prefixAfter.endOffset == prefixBefore.endOffset, "prefix.endOffset must be preserved by idempotent setEntry")
        #expect(mainAfter.startOffset == mainBefore.startOffset, "main.startOffset must be preserved by idempotent setEntry")
        #expect(mainAfter.endOffset == mainBefore.endOffset, "main.endOffset must be preserved by idempotent setEntry")
        #expect(cachedAfter == cachedBefore, "cachedByteCount must be unchanged by idempotent setEntry")

        // lastPlaybackOffset survival — read directly via the test seam.
        // (Cannot observe via trimFront here: trimFrontLocked only sheds bytes
        // once `.main` exceeds maxCacheSize (256 MB); this fixture writes 50 MB,
        // so trimFront is correctly a no-op regardless of lastPlaybackOffset.)
        #expect(
            store.testInspectLastPlaybackOffset() == playbackOffsetBefore,
            "lastPlaybackOffset must survive idempotent setEntry"
        )
    }

    /// A `contentType` mismatch (different MIME, e.g. server switched the
    /// transcoded variant) still busts the cache — the new content is not
    /// the same bytes, so old chunks are invalid.
    @Test func setEntry_sameVideoIdAndTotalSize_butDifferentContentType_replaces() {
        let store = CacheStore()
        let totalSize: Int64 = 200 * 1024 * 1024
        store.setEntry(videoId: "v", totalSize: totalSize, contentType: "video/mp4", resumeByte: 0)
        _ = store.writeChunk(videoId: "v", toRegion: .prefix, chunk: Data(repeating: 0xAA, count: 1024))
        #expect(store.cachedByteCount(videoId: "v") == 1024)

        store.setEntry(videoId: "v", totalSize: totalSize, contentType: "video/webm", resumeByte: 0)
        // contentType changed → entry replaced → chunks dropped.
        #expect(store.cachedByteCount(videoId: "v") == 0)
    }

    @Test func setEntry_resumeBytePastTotalSize_clampsAndSkipsMain() {
        // Pathological input: resumeByte > totalSize (corrupt saved
        // progress, re-encoded video shrinking under us). `setEntry` must
        // clamp resumeByte and skip the degenerate main region rather than
        // creating one with `startOffset == totalSize` and zero capacity.
        let store = CacheStore()
        let totalSize: Int64 = 100 * 1024 * 1024
        let bogusResumeByte: Int64 = totalSize + 50_000_000
        store.setEntry(
            videoId: "v",
            totalSize: totalSize,
            contentType: "video/mp4",
            resumeByte: bogusResumeByte
        )
        // Prefix is always created.
        #expect(store.regionStatus(videoId: "v", region: .prefix) != nil)
        // Main MUST NOT exist when clamped resumeByte == totalSize.
        #expect(store.regionStatus(videoId: "v", region: .main) == nil)
    }

    @Test func writeChunk_afterClear_returnsFalse() {
        // After `clear()` removes the entry, `writeChunk` must report
        // failure rather than silently creating a new entry. The preloader
        // relies on this to know its chunk was dropped (the loop checks the
        // return value implicitly via `cachedByteCount`).
        let store = CacheStore()
        store.setEntry(
            videoId: "v",
            totalSize: 100 * 1024 * 1024,
            contentType: "video/mp4",
            resumeByte: 0
        )
        store.clear()
        let ok = store.writeChunk(videoId: "v", toRegion: .prefix, chunk: Data(repeating: 0, count: 256))
        #expect(ok == false)
        #expect(store.cachedByteCount(videoId: "v") == 0)
    }

    @Test func updatePlaybackPosition_withMainAtNonZero_trimsCorrectly() {
        // When main starts at a non-zero offset, the trim math must subtract
        // main.startOffset from the playback byte before deciding how much to
        // shed; otherwise it would over-trim and remove keyframe references.
        // We verify by writing past the trim threshold and observing that the
        // main.startOffset advances by approximately the trim amount.
        let store = CacheStore()
        // Total size large enough that prefixSize lands at 50 MB ceiling and
        // main has plenty of room.
        let totalSize: Int64 = 10 * 1024 * 1024 * 1024 // 10 GB
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        #expect(prefixSize == CacheStore.maxPrefixSize)  // 50 MB ceiling (computePrefixSize clamp)
        let resumeByte = prefixSize
        store.setEntry(videoId: "v", totalSize: totalSize, contentType: "video/mp4", resumeByte: resumeByte)

        // Fill main to just over trimThreshold so the auto-trim path kicks in.
        let chunk = Data(repeating: 0xBB, count: CacheStore.chunkSize)
        var written: Int = 0
        // Need to position playback first so the auto-trim during writeChunk
        // has room to shed bytes. Place playback near the end of what we're
        // about to write so there's plenty of safe trim margin.
        let plannedTotal = CacheStore.trimThreshold + 5 * CacheStore.chunkSize
        let playbackByte = resumeByte + Int64(plannedTotal - 50 * 1024 * 1024) // 50 MB before tail
        let duration: Double = 1000
        let avgByterate = Double(totalSize) / duration
        let seconds = Double(playbackByte) / avgByterate
        store.updatePlaybackPosition(videoId: "v", seconds: seconds, duration: duration)

        let mainStartBefore = store.regionStatus(videoId: "v", region: .main)?.startOffset ?? 0
        while written < plannedTotal {
            _ = store.writeChunk(videoId: "v", toRegion: .main, chunk: chunk)
            written += chunk.count
        }
        let mainStartAfter = store.regionStatus(videoId: "v", region: .main)?.startOffset ?? 0

        // main.startOffset advanced (auto-trim during writeChunk shed front).
        #expect(mainStartAfter > mainStartBefore)
        // main.startOffset still >= original resumeByte (we never go before
        // where we initially started — trim only moves forward).
        #expect(mainStartAfter >= resumeByte)
    }

    // MARK: - resetMainRegion (reseed-after-large-scrub)

    /// Replace `.main` with a fresh empty region anchored at the new byte while
    /// leaving `.prefix` untouched (moov-atom protection). Prefix bytes and
    /// metadata survive intact; main is empty at the new offset.
    @Test func resetMain_replacesMain_keepsPrefix() {
        let store = CacheStore()
        let totalSize: Int64 = 200 * 1024 * 1024  // 200 MB → both regions
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        let resumeByte: Int64 = 80 * 1024 * 1024
        store.setEntry(videoId: "v", totalSize: totalSize, contentType: "video/mp4", resumeByte: resumeByte)
        // Prefix: 8 MB written (full to prefixSize).
        Self.writeChunksToRegion(store: store, videoId: "v", region: .prefix, bytes: Int(prefixSize), byte: 0xAA)
        // Main: 4 MB written at resumeByte.
        Self.writeChunksToRegion(store: store, videoId: "v", region: .main, bytes: 4 * 1024 * 1024, byte: 0xBB)

        let prefixBefore = store.regionStatus(videoId: "v", region: .prefix)
        store.resetMainRegion(videoId: "v", newStartOffset: 120 * 1024 * 1024)
        let prefixAfter = store.regionStatus(videoId: "v", region: .prefix)
        let mainAfter = store.regionStatus(videoId: "v", region: .main)

        // Prefix unchanged.
        #expect(prefixAfter?.startOffset == prefixBefore?.startOffset)
        #expect(prefixAfter?.endOffset == prefixBefore?.endOffset)
        // Main reanchored at the requested byte, empty.
        let expectedStart: Int64 = 120 * 1024 * 1024
        #expect(mainAfter?.startOffset == expectedStart)
        #expect(mainAfter?.endOffset == expectedStart)
    }

    @Test func resetMain_clampsBelowPrefixEnd() {
        // newStartOffset that would precede prefix.endOffset is clamped UP to
        // prefixEnd so the regions stay disjoint and main never overlaps prefix.
        let store = CacheStore()
        let totalSize: Int64 = 200 * 1024 * 1024
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)  // 8 MB
        let resumeByte = prefixSize + 1024
        store.setEntry(videoId: "v", totalSize: totalSize, contentType: "video/mp4", resumeByte: resumeByte)
        Self.writeChunksToRegion(store: store, videoId: "v", region: .prefix, bytes: Int(prefixSize), byte: 0xAA)

        // Try to reset main before prefix ends (4 MB < 8 MB prefixEnd).
        store.resetMainRegion(videoId: "v", newStartOffset: 4 * 1024 * 1024)
        let mainAfter = store.regionStatus(videoId: "v", region: .main)
        // Clamped UP to prefix.endOffset (= prefixSize since prefix is full).
        #expect(mainAfter?.startOffset == prefixSize)
    }

    @Test func resetMain_clampsAtOrAboveTotalSize_removesMain() {
        // newStartOffset >= totalSize would create a degenerate zero-length
        // region; remove main entirely instead.
        let store = CacheStore()
        let totalSize: Int64 = 200 * 1024 * 1024
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        store.setEntry(videoId: "v", totalSize: totalSize, contentType: "video/mp4", resumeByte: prefixSize)
        Self.writeChunksToRegion(store: store, videoId: "v", region: .main, bytes: 1024, byte: 0xBB)
        #expect(store.regionStatus(videoId: "v", region: .main) != nil)

        store.resetMainRegion(videoId: "v", newStartOffset: totalSize)
        #expect(store.regionStatus(videoId: "v", region: .main) == nil)

        // Re-seed and try past totalSize — also removes. `setEntry` is
        // idempotent on matching (videoId, totalSize, contentType), so we
        // `clear()` first to force a fresh entry that re-creates `.main`.
        store.clear()
        store.setEntry(videoId: "v", totalSize: totalSize, contentType: "video/mp4", resumeByte: prefixSize)
        Self.writeChunksToRegion(store: store, videoId: "v", region: .main, bytes: 1024, byte: 0xBB)
        store.resetMainRegion(videoId: "v", newStartOffset: totalSize + 1_000_000)
        #expect(store.regionStatus(videoId: "v", region: .main) == nil)
    }

    @Test func resetMain_wrongVideoId_noop() {
        let store = CacheStore()
        let totalSize: Int64 = 200 * 1024 * 1024
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        store.setEntry(videoId: "v", totalSize: totalSize, contentType: "video/mp4", resumeByte: prefixSize)
        Self.writeChunksToRegion(store: store, videoId: "v", region: .main, bytes: 4096, byte: 0xBB)
        let mainBefore = store.regionStatus(videoId: "v", region: .main)

        store.resetMainRegion(videoId: "other", newStartOffset: 100 * 1024 * 1024)
        let mainAfter = store.regionStatus(videoId: "v", region: .main)
        #expect(mainAfter?.startOffset == mainBefore?.startOffset)
        #expect(mainAfter?.endOffset == mainBefore?.endOffset)
    }

    @Test func resetMain_missingEntry_noop() {
        let store = CacheStore()
        // No entry installed; resetMain must not crash or create an entry.
        store.resetMainRegion(videoId: "v", newStartOffset: 100 * 1024 * 1024)
        #expect(store.currentVideoId() == nil)
        #expect(store.regionStatus(videoId: "v", region: .main) == nil)
    }

    @Test func resetMain_doesNotResetLastPlaybackOffset() {
        // Verify `lastPlaybackOffset` survives a reseed. We assert this
        // indirectly via trim behavior: with playback offset set high, the
        // first fill triggers auto-trim. Reseed at a new byte and refill —
        // trim must STILL fire (would not if lastPlaybackOffset were reset to
        // 0, since `safeTrimBound = -30MB` would make every trim a no-op).
        let store = CacheStore()
        let totalSize: Int64 = 10 * 1024 * 1024 * 1024  // 10 GB so prefix is at 50 MB cap
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        #expect(prefixSize == CacheStore.maxPrefixSize)
        let resumeByte = prefixSize
        store.setEntry(videoId: "v", totalSize: totalSize, contentType: "video/mp4", resumeByte: resumeByte)

        // Place playback far enough into the file that future trims have margin.
        let duration: Double = 1000
        let avgByterate = Double(totalSize) / duration
        let plannedTotal = CacheStore.trimThreshold + 5 * CacheStore.chunkSize
        let playbackByte = resumeByte + Int64(plannedTotal - 50_000_000)
        let seconds = Double(playbackByte) / avgByterate
        store.updatePlaybackPosition(videoId: "v", seconds: seconds, duration: duration)

        // Fill past trimThreshold — auto-trim during writeChunk should fire.
        let chunk = Data(repeating: 0xBB, count: CacheStore.chunkSize)
        var mainStartBefore = store.regionStatus(videoId: "v", region: .main)?.startOffset ?? 0
        var written = 0
        while written < plannedTotal {
            _ = store.writeChunk(videoId: "v", toRegion: .main, chunk: chunk)
            written += chunk.count
        }
        let mainStartAfterFirstTrim = store.regionStatus(videoId: "v", region: .main)?.startOffset ?? 0
        #expect(mainStartAfterFirstTrim > mainStartBefore, "first auto-trim must fire (sanity)")

        // RESEED at a new byte. Playback offset must survive this call.
        let reseedAt: Int64 = playbackByte + 100_000_000
        store.resetMainRegion(videoId: "v", newStartOffset: reseedAt)
        // Place playback further forward so the next batch can trim again.
        let playback2 = reseedAt + Int64(plannedTotal - 50_000_000)
        store.updatePlaybackPosition(videoId: "v", seconds: Double(playback2) / avgByterate, duration: duration)

        mainStartBefore = store.regionStatus(videoId: "v", region: .main)?.startOffset ?? 0
        written = 0
        while written < plannedTotal {
            _ = store.writeChunk(videoId: "v", toRegion: .main, chunk: chunk)
            written += chunk.count
        }
        let mainStartAfterSecondTrim = store.regionStatus(videoId: "v", region: .main)?.startOffset ?? 0
        // If `lastPlaybackOffset` had been zeroed by resetMainRegion, the
        // second trim could not advance main (safeTrimBound goes negative).
        // The advance proves the playback offset survived the reseed.
        #expect(mainStartAfterSecondTrim > mainStartBefore, "auto-trim must STILL fire after reseed — proves lastPlaybackOffset survived")
    }

    /// When the clamped `newStartOffset` equals the existing `.main.startOffset`
    /// AND main already has cached bytes, `resetMainRegion` preserves the
    /// region instead of wiping it. This is the backward-scrub-into-prefix
    /// optimisation: a scrub byte below `prefixEnd` clamps up to prefixEnd,
    /// which is the same place main is anchored — wiping it would discard
    /// useful bytes for no benefit. The store keeps the region intact and
    /// the preloader's resume-from-tail logic picks up from `main.endOffset`.
    @Test func resetMain_clampedEqualsPreviousStart_preservesMain() {
        let store = CacheStore()
        let totalSize: Int64 = 200 * 1024 * 1024
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        let resumeByte = prefixSize
        store.setEntry(videoId: "v", totalSize: totalSize, contentType: "video/mp4", resumeByte: resumeByte)
        // Fill prefix so prefix.endOffset == prefixSize (the clamp's lower
        // bound is `prefix.endOffset`, not `prefixSize`).
        Self.writeChunksToRegion(store: store, videoId: "v", region: .prefix, bytes: Int(prefixSize), byte: 0xAA)
        // Populate main with a few MB of bytes at prefixEnd.
        Self.writeChunksToRegion(store: store, videoId: "v", region: .main, bytes: 4 * 1024 * 1024, byte: 0xBB)
        let mainBefore = store.regionStatus(videoId: "v", region: .main)
        let bytesBefore = mainBefore.map { Int($0.endOffset - $0.startOffset) } ?? 0
        #expect(bytesBefore > 0, "precondition: main must hold cached bytes")

        // Reseed to a byte WAY below prefixEnd — gets clamped UP to prefixEnd.
        // Since main is already at prefixEnd, clamped == previousStart and the
        // short-circuit must keep main intact.
        store.resetMainRegion(videoId: "v", newStartOffset: 4096)

        let mainAfter = store.regionStatus(videoId: "v", region: .main)
        #expect(mainAfter?.startOffset == prefixSize,
                "main.startOffset must remain at prefixEnd after the short-circuit")
        // The key invariant: cached bytes survive.
        let bytesAfter = mainAfter.map { Int($0.endOffset - $0.startOffset) } ?? 0
        #expect(bytesAfter == bytesBefore,
                "main's cached bytes must survive the no-op clamp short-circuit")
    }

    /// The short-circuit only fires when `clamped == previousStart`. A
    /// clamped target ABOVE the previous start (forward scrub past
    /// `main.endOffset` for instance) must still wipe and re-anchor — the
    /// short-circuit is scoped to the specific wasteful pattern, not a
    /// blanket "skip when there are cached bytes" check.
    @Test func resetMain_clampedAboveStart_stillWipes() {
        let store = CacheStore()
        let totalSize: Int64 = 200 * 1024 * 1024
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        let resumeByte = prefixSize
        store.setEntry(videoId: "v", totalSize: totalSize, contentType: "video/mp4", resumeByte: resumeByte)
        Self.writeChunksToRegion(store: store, videoId: "v", region: .main, bytes: 4 * 1024 * 1024, byte: 0xBB)
        let bytesBefore = store.regionStatus(videoId: "v", region: .main)
            .map { Int($0.endOffset - $0.startOffset) } ?? 0
        #expect(bytesBefore > 0)

        // Forward reseed past current main's bytes.
        let newStart: Int64 = 100 * 1024 * 1024
        store.resetMainRegion(videoId: "v", newStartOffset: newStart)

        let mainAfter = store.regionStatus(videoId: "v", region: .main)
        #expect(mainAfter?.startOffset == newStart)
        #expect(mainAfter?.endOffset == newStart, "main must be empty after a forward wipe-and-reanchor")
    }

    @Test func resetMain_smallFileNoMain_noop() {
        // totalSize ≤ prefixSize → no main exists. resetMain must not create one.
        let store = CacheStore()
        store.setEntry(videoId: "v", totalSize: 4096, contentType: "video/mp4", resumeByte: 0)
        #expect(store.regionStatus(videoId: "v", region: .main) == nil)
        store.resetMainRegion(videoId: "v", newStartOffset: 1024)
        #expect(store.regionStatus(videoId: "v", region: .main) == nil)
    }

    /// Write `bytes` zero-filled chunks of value `byte` into an existing
    /// entry's region. Unlike `setEntryAndFill`, the entry must already
    /// exist — this helper only issues `writeChunk` calls. Used by the
    /// resetMainRegion tests to populate regions selectively before/after
    /// the reseed call.
    private static func writeChunksToRegion(
        store: CacheStore,
        videoId: String,
        region: CacheStore.RegionID,
        bytes: Int,
        byte: UInt8
    ) {
        var written = 0
        while written < bytes {
            let chunkBytes = min(CacheStore.chunkSize, bytes - written)
            let chunk = Data(repeating: byte, count: chunkBytes)
            _ = store.writeChunk(videoId: videoId, toRegion: region, chunk: chunk)
            written += chunkBytes
        }
    }
}
