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

    /// Write `payload` into the store as a sequence of fixed-size chunks.
    private static func seed(
        store: CacheStore,
        videoId: String,
        startOffset: Int64 = 0,
        totalSize: Int64? = nil,
        contentType: String = "video/mp4",
        payload: Data,
        chunkSize: Int = CacheStore.chunkSize
    ) {
        store.setEntry(
            videoId: videoId,
            startOffset: startOffset,
            totalSize: totalSize ?? Int64(payload.count) + startOffset,
            contentType: contentType
        )
        var offset = 0
        while offset < payload.count {
            let end = min(offset + chunkSize, payload.count)
            let chunk = payload[offset..<end]
            _ = store.writeChunk(videoId: videoId, chunk: Data(chunk))
            offset = end
        }
    }

    // MARK: - Reads

    @Test func readData_happyPath_returnsExactBytes() {
        let store = CacheStore()
        let payload = Self.makePayload(size: 4096)
        Self.seed(store: store, videoId: "v", payload: payload)

        let slice = store.readData(videoId: "v", offset: 100, length: 256)
        #expect(slice?.count == 256)
        #expect(slice == payload[100..<356])
    }

    @Test func readData_spansChunkBoundary_returnsContiguousData() {
        let store = CacheStore()
        // Size chosen to straddle the 512KB chunk boundary
        let payload = Self.makePayload(size: 600 * 1024)
        Self.seed(store: store, videoId: "v", payload: payload)

        let offset: Int64 = Int64(CacheStore.chunkSize) - 128
        let slice = store.readData(videoId: "v", offset: offset, length: 256)
        #expect(slice?.count == 256)
        let expected = payload[Int(offset)..<Int(offset) + 256]
        #expect(slice == Data(expected))
    }

    @Test func readData_lengthLargerThanAvailable_returnsOnlyAvailable() {
        let store = CacheStore()
        let payload = Self.makePayload(size: 1024)
        Self.seed(store: store, videoId: "v", payload: payload)

        // Request beyond end: should clamp to what's available.
        let slice = store.readData(videoId: "v", offset: 900, length: 4096)
        #expect(slice?.count == 124)
        #expect(slice == payload.suffix(124))
    }

    @Test func readData_offsetPastEnd_returnsNil() {
        let store = CacheStore()
        let payload = Self.makePayload(size: 1024)
        Self.seed(store: store, videoId: "v", payload: payload)

        #expect(store.readData(videoId: "v", offset: 1025, length: 16) == nil)
        #expect(store.readData(videoId: "v", offset: 1024, length: 16) == nil) // exactly at end
    }

    @Test func readData_negativeOffset_returnsNil() {
        let store = CacheStore()
        let payload = Self.makePayload(size: 1024)
        Self.seed(store: store, videoId: "v", payload: payload)

        #expect(store.readData(videoId: "v", offset: -1, length: 16) == nil)
    }

    @Test func readData_offsetBeforeStartOffset_returnsNil() {
        let store = CacheStore()
        let payload = Self.makePayload(size: 1024)
        // Seed with a non-zero startOffset; reads before it must return nil.
        Self.seed(store: store, videoId: "v", startOffset: 5_000, payload: payload)

        #expect(store.readData(videoId: "v", offset: 0, length: 16) == nil)
        #expect(store.readData(videoId: "v", offset: 4_999, length: 16) == nil)
    }

    @Test func readData_wrongVideoId_returnsNil() {
        let store = CacheStore()
        let payload = Self.makePayload(size: 1024)
        Self.seed(store: store, videoId: "v", payload: payload)

        #expect(store.readData(videoId: "other", offset: 0, length: 16) == nil)
    }

    @Test func readData_noEntry_returnsNil() {
        let store = CacheStore()
        #expect(store.readData(videoId: "v", offset: 0, length: 16) == nil)
    }

    // MARK: - cacheStatus / cachedByteCount / currentVideoId

    @Test func cacheStatus_returnsCorrectRange() {
        let store = CacheStore()
        let payload = Self.makePayload(size: 2048)
        Self.seed(store: store, videoId: "v", startOffset: 1_000, totalSize: 10_000, payload: payload)

        let status = store.cacheStatus(videoId: "v")
        #expect(status?.startOffset == Int64(1_000))
        #expect(status?.endOffset == Int64(1_000 + 2_048))
        #expect(status?.totalSize == Int64(10_000))
        #expect(status?.contentType == "video/mp4")
    }

    @Test func cacheStatus_wrongVideoId_returnsNil() {
        let store = CacheStore()
        let payload = Self.makePayload(size: 1024)
        Self.seed(store: store, videoId: "v", payload: payload)
        #expect(store.cacheStatus(videoId: "other") == nil)
    }

    @Test func cachedByteCount_reflectsWrittenChunks() {
        let store = CacheStore()
        let payload = Self.makePayload(size: 3_000)
        Self.seed(store: store, videoId: "v", payload: payload, chunkSize: 512)

        #expect(store.cachedByteCount(videoId: "v") == 3_000)
        #expect(store.cachedByteCount(videoId: "other") == 0)
    }

    @Test func currentVideoId_reflectsActiveEntry() {
        let store = CacheStore()
        #expect(store.currentVideoId() == nil)
        Self.seed(store: store, videoId: "v", payload: Self.makePayload(size: 64))
        #expect(store.currentVideoId() == "v")
        store.clear()
        #expect(store.currentVideoId() == nil)
    }

    // MARK: - writeChunk

    @Test func writeChunk_withMismatchedVideoId_returnsFalse() {
        let store = CacheStore()
        store.setEntry(videoId: "v", startOffset: 0, totalSize: 1_000, contentType: "video/mp4")
        let ok = store.writeChunk(videoId: "other", chunk: Data(repeating: 0, count: 100))
        #expect(ok == false)
        #expect(store.cachedByteCount(videoId: "v") == 0)
    }

    @Test func writeChunk_withNoEntry_returnsFalse() {
        let store = CacheStore()
        let ok = store.writeChunk(videoId: "v", chunk: Data(repeating: 0, count: 100))
        #expect(ok == false)
    }

    @Test func writeChunk_succeedsForMatchingEntry() {
        let store = CacheStore()
        store.setEntry(videoId: "v", startOffset: 0, totalSize: 1_000, contentType: "video/mp4")
        let ok = store.writeChunk(videoId: "v", chunk: Data(repeating: 0xAB, count: 200))
        #expect(ok == true)
        #expect(store.cachedByteCount(videoId: "v") == 200)
    }

    // MARK: - setEntry

    @Test func setEntry_replacesExistingEntry() {
        let store = CacheStore()
        store.setEntry(videoId: "a", startOffset: 0, totalSize: 1_000, contentType: "video/mp4")
        _ = store.writeChunk(videoId: "a", chunk: Data(repeating: 1, count: 100))
        #expect(store.cachedByteCount(videoId: "a") == 100)

        store.setEntry(videoId: "b", startOffset: 500, totalSize: 2_000, contentType: "video/webm")
        #expect(store.cachedByteCount(videoId: "a") == 0)
        #expect(store.currentVideoId() == "b")
        let status = store.cacheStatus(videoId: "b")
        #expect(status?.startOffset == 500)
        #expect(status?.totalSize == 2_000)
        #expect(status?.contentType == "video/webm")
    }

    // MARK: - trimFront

    @Test func trimFront_whenBelowMaxCacheSize_isNoOp() {
        let store = CacheStore()
        // Well below maxCacheSize (256MB) -> nothing to trim.
        Self.seed(store: store, videoId: "v", payload: Self.makePayload(size: 10 * 1024))
        // Set a playback offset that would otherwise be "trim eligible".
        store.updatePlaybackPosition(videoId: "v", seconds: 100, duration: 100)

        let removed = store.trimFront(videoId: "v")
        #expect(removed == 0)
        #expect(store.cachedByteCount(videoId: "v") == 10 * 1024)
    }

    @Test func trimFront_wrongVideoId_returnsZero() {
        let store = CacheStore()
        Self.seed(store: store, videoId: "v", payload: Self.makePayload(size: 1024))
        let removed = store.trimFront(videoId: "nope")
        #expect(removed == 0)
    }

    @Test func trimFront_noEntry_returnsZero() {
        let store = CacheStore()
        #expect(store.trimFront(videoId: "v") == 0)
    }

    // MARK: - emergencyTrim

    @Test func emergencyTrim_belowTarget_returnsZero() {
        let store = CacheStore()
        Self.seed(store: store, videoId: "v", payload: Self.makePayload(size: 2_000))
        let removed = store.emergencyTrim(videoId: "v", targetSize: 10_000)
        #expect(removed == 0)
        #expect(store.cachedByteCount(videoId: "v") == 2_000)
    }

    @Test func emergencyTrim_aboveTarget_dropsChunksFromFront() {
        let store = CacheStore()
        // Seed 10 chunks of 1 KB each = 10 KB total.
        store.setEntry(videoId: "v", startOffset: 0, totalSize: 10_000, contentType: "video/mp4")
        for i in 0..<10 {
            _ = store.writeChunk(videoId: "v", chunk: Data(repeating: UInt8(i), count: 1_024))
        }
        #expect(store.cachedByteCount(videoId: "v") == 10 * 1_024)

        // Target 5 KB — should drop ~5 chunks from front (overflow=5120, whole chunks only).
        let removed = store.emergencyTrim(videoId: "v", targetSize: 5 * 1_024)
        #expect(removed >= 5 * 1_024)
        #expect(store.cachedByteCount(videoId: "v") <= 5 * 1_024)
        // startOffset advances by `removed` so reads start at the new boundary.
        let status = store.cacheStatus(videoId: "v")
        #expect(status?.startOffset == Int64(removed))
    }

    @Test func emergencyTrim_wrongVideoId_returnsZero() {
        let store = CacheStore()
        Self.seed(store: store, videoId: "v", payload: Self.makePayload(size: 10_000))
        let removed = store.emergencyTrim(videoId: "nope", targetSize: 0)
        #expect(removed == 0)
        #expect(store.cachedByteCount(videoId: "v") == 10_000)
    }

    // MARK: - clear

    @Test func clear_emptiesEverything() {
        let store = CacheStore()
        Self.seed(store: store, videoId: "v", payload: Self.makePayload(size: 1024))
        #expect(store.cacheStatus(videoId: "v") != nil)
        store.clear()
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
        Self.seed(store: store, videoId: "v", payload: Self.makePayload(size: 1024))
        store.updatePlaybackPosition(videoId: "v", seconds: 10, duration: 0)
        // No crash; reads still work.
        #expect(store.readData(videoId: "v", offset: 0, length: 16)?.count == 16)
    }
}
