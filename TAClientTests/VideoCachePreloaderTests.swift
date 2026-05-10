import Testing
import Foundation
@testable import TAClient

/// Baseline safety-net tests for `VideoCachePreloader` (renamed from
/// `VideoCache` in Task 10 / C1b).
///
/// These tests lock in the behaviour of `startPreloadWithRetry`, `readData`,
/// `cacheStatus`, `clear`, and `updatePlaybackPosition`. They were written
/// before the Task 9 (C1a) internal extraction of `CacheStore` and the
/// Task 10 rename, and continue to act as a regression net covering the
/// end-to-end preloader → store path.
///
/// Placed inside `DataLayerSuite` (`.serialized`) because
/// `VideoCachePreloader.shared` is a process-wide singleton: parallel tests
/// would race on its entry and MockURLProtocol state.
extension DataLayerSuite {
@Suite(.serialized) struct VideoCachePreloaderTests {

    init() {
        MockResponse.tearDown()
        VideoCachePreloader.testSessionConfigurationOverride = nil
    }

    // MARK: - Helpers

    /// Build a deterministic byte pattern so tests can assert correctness at
    /// arbitrary offsets. Byte i = UInt8(i % 251).
    private static func makePayload(size: Int) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(size)
        for i in 0..<size {
            bytes.append(UInt8(i % 251))
        }
        return Data(bytes)
    }

    /// Generic async poller: invoke `predicate` every 20 ms until it returns
    /// `true` or the timeout elapses. Returns the final predicate result.
    private static func pollUntil(
        timeoutSeconds: Double = 5,
        _ predicate: @Sendable () async -> Bool
    ) async -> Bool {
        let step: UInt64 = 20_000_000 // 20 ms
        let iterations = Int((timeoutSeconds * 1_000_000_000) / Double(step))
        for _ in 0..<iterations {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: step)
        }
        return false
    }

    /// Poll the cache until preload finishes (cachedByteCount >= expected) or
    /// the timeout elapses. Returns `true` iff the cache reached the target
    /// size before the timeout.
    private static func waitForPreloadComplete(
        videoId: String,
        expectedBytes: Int,
        timeoutSeconds: Double = 5
    ) async -> Bool {
        await pollUntil(timeoutSeconds: timeoutSeconds) {
            guard let status = await VideoCachePreloader.shared.cacheStatus(videoId: videoId) else {
                return false
            }
            return Int(status.endOffset - status.startOffset) >= expectedBytes
        }
    }

    /// Configure the shared singleton to use MockURLProtocol and serve a
    /// fixed payload for any request.
    private static func installMockResponding(with payload: Data, statusCode: Int = 200) {
        VideoCachePreloader.testSessionConfigurationOverride = MockResponse.makeConfiguration()
        let url = URL(string: "https://ta.example.com")!
        MockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "video/mp4",
                    "Content-Length": "\(payload.count)"
                ]
            )!
            return (response, payload)
        }
    }

    // MARK: - Tests

    @Test func videoCache_preloadThenRead_roundtrip() async {
        // Size spans multiple 512 KB chunks so the chunk-read path is exercised.
        let payloadSize = 600 * 1024 // 600 KB -> 2 chunks (512 KB + 88 KB)
        let payload = Self.makePayload(size: payloadSize)
        Self.installMockResponding(with: payload)
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()

        let videoId = "vid-roundtrip"
        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: videoId,
            url: URL(string: "https://ta.example.com/media/\(videoId).mp4")!,
            token: "test-token",
            startPosition: 0,
            duration: 0,
            maxRetries: 0
        )

        let finished = await Self.waitForPreloadComplete(videoId: videoId, expectedBytes: payloadSize)
        #expect(finished, "Preload did not complete within timeout")

        // Read at offset 0
        let firstSlice = await VideoCachePreloader.shared.readData(videoId: videoId, offset: 0, length: 256)
        #expect(firstSlice != nil)
        #expect(firstSlice?.count == 256)
        #expect(firstSlice == payload.prefix(256))

        // Read spanning a chunk boundary (chunk size = 512 KB)
        let boundaryOffset: Int64 = 512 * 1024 - 128
        let boundarySlice = await VideoCachePreloader.shared.readData(
            videoId: videoId,
            offset: boundaryOffset,
            length: 256
        )
        #expect(boundarySlice != nil)
        #expect(boundarySlice?.count == 256)
        let expectedBoundary = payload[Int(boundaryOffset)..<Int(boundaryOffset) + 256]
        #expect(boundarySlice == Data(expectedBoundary))

        // Read near end: request more than available -> should return only what's available
        let tailOffset = Int64(payloadSize - 100)
        let tailSlice = await VideoCachePreloader.shared.readData(
            videoId: videoId,
            offset: tailOffset,
            length: 1024
        )
        #expect(tailSlice != nil)
        #expect(tailSlice?.count == 100)
        #expect(tailSlice == payload.suffix(100))

        // cacheStatus reports the expected range.
        let status = await VideoCachePreloader.shared.cacheStatus(videoId: videoId)
        #expect(status != nil)
        #expect(status?.startOffset == 0)
        #expect(status?.endOffset == Int64(payloadSize))
        #expect(status?.contentType == "video/mp4")

        await VideoCachePreloader.shared.clear()
    }

    @Test func videoCache_updatePlaybackPosition_tracksLastOffset() async {
        // `lastPlaybackOffset` is private. We can only observe indirectly that
        // calls with matching/mismatching videoIds don't throw and that the
        // method is safe to invoke at any time (including with no entry).
        // The baseline contract: updatePlaybackPosition must be a no-op when
        // there is no entry, when the videoId doesn't match, or when duration
        // is non-positive — and must not crash or corrupt subsequent reads.

        await VideoCachePreloader.shared.clear()

        // No entry: call should be a safe no-op.
        await VideoCachePreloader.shared.updatePlaybackPosition(
            videoId: "nonexistent",
            seconds: 10,
            duration: 60
        )
        #expect(await VideoCachePreloader.shared.cacheStatus(videoId: "nonexistent") == nil)

        // Seed a real entry and verify updatePlaybackPosition with the correct
        // videoId is accepted, and the cache remains readable afterwards.
        let payload = Self.makePayload(size: 128 * 1024)
        Self.installMockResponding(with: payload)
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        let videoId = "vid-track-offset"
        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: videoId,
            url: URL(string: "https://ta.example.com/media/\(videoId).mp4")!,
            token: "test-token",
            startPosition: 0,
            duration: 0,
            maxRetries: 0
        )
        let finished = await Self.waitForPreloadComplete(videoId: videoId, expectedBytes: payload.count)
        #expect(finished)

        // Matching videoId + valid duration: accepted, no throw.
        await VideoCachePreloader.shared.updatePlaybackPosition(
            videoId: videoId,
            seconds: 5,
            duration: 60
        )

        // Mismatching videoId: no-op.
        await VideoCachePreloader.shared.updatePlaybackPosition(
            videoId: "other-vid",
            seconds: 5,
            duration: 60
        )

        // Zero duration: guarded no-op.
        await VideoCachePreloader.shared.updatePlaybackPosition(
            videoId: videoId,
            seconds: 5,
            duration: 0
        )

        // Reads still succeed after the position updates.
        let slice = await VideoCachePreloader.shared.readData(videoId: videoId, offset: 0, length: 64)
        #expect(slice?.count == 64)
        #expect(slice == payload.prefix(64))

        await VideoCachePreloader.shared.clear()
    }

    @Test func videoCache_clear_emptiesEntry() async {
        let payload = Self.makePayload(size: 64 * 1024)
        Self.installMockResponding(with: payload)
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()

        let videoId = "vid-clear"
        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: videoId,
            url: URL(string: "https://ta.example.com/media/\(videoId).mp4")!,
            token: "test-token",
            startPosition: 0,
            duration: 0,
            maxRetries: 0
        )
        let finished = await Self.waitForPreloadComplete(videoId: videoId, expectedBytes: payload.count)
        #expect(finished)
        #expect(await VideoCachePreloader.shared.cacheStatus(videoId: videoId) != nil)

        await VideoCachePreloader.shared.clear()

        #expect(await VideoCachePreloader.shared.cacheStatus(videoId: videoId) == nil)
        // Reads after clear return nil.
        #expect(await VideoCachePreloader.shared.readData(videoId: videoId, offset: 0, length: 16) == nil)
    }

    // MARK: - Task 14 / D2 — Memory-pressure split
    //
    // `DispatchSource.makeMemoryPressureSource` cannot be triggered from
    // tests (no public API to synthesise `.warning` / `.critical` events),
    // so we exercise `handleMemoryPressure(event:)` directly. The production
    // DispatchSource handler is a one-liner that forwards to this method, so
    // the logic-split is the interesting surface to cover.

    @Test func preloader_memoryWarning_emergencyTrims() async {
        // Seed a cache entry that exceeds `maxCacheSize / 2` so the trim path
        // actually has work to do. Use a direct store write (preloader would
        // cap at maxCacheSize via the download loop) — the handler operates
        // on the store regardless of how bytes got there.
        await VideoCachePreloader.shared.clear()
        let videoId = "vid-mem-warning"
        let targetSize = CacheStore.maxCacheSize / 2
        // Seed just above half-cache so we have a measurable trim.
        let seedBytes = targetSize + (10 * 1024 * 1024)
        let store = VideoCachePreloader.shared.store
        store.setEntry(
            videoId: videoId,
            startOffset: 0,
            totalSize: Int64(seedBytes * 2),
            contentType: "video/mp4"
        )
        // Write in `chunkSize`-bounded chunks so `writeChunk` accepts them.
        var remaining = seedBytes
        var writeOffset = 0
        while remaining > 0 {
            let size = min(CacheStore.chunkSize, remaining)
            let chunk = Data(repeating: UInt8(writeOffset & 0xFF), count: size)
            _ = store.writeChunk(videoId: videoId, chunk: chunk)
            remaining -= size
            writeOffset &+= 1
        }

        let before = store.cachedByteCount(videoId: videoId)
        #expect(before >= targetSize, "precondition: seeded more than target")

        // Fire warning-level pressure.
        VideoCachePreloader.shared.handleMemoryPressure(event: .warning)

        let after = store.cachedByteCount(videoId: videoId)
        // Entry must still exist (warning does not clear).
        #expect(store.currentVideoId() == videoId, "warning must not clear the entry")
        #expect(after > 0, "warning must not empty the cache")
        #expect(after <= targetSize + CacheStore.chunkSize, "cache must be trimmed at or below target (±one chunk)")
        #expect(after < before, "cache must shrink after warning-level pressure")

        await VideoCachePreloader.shared.clear()
    }

    @Test func preloader_memoryCritical_clearsStore() async {
        await VideoCachePreloader.shared.clear()
        let videoId = "vid-mem-critical"
        let store = VideoCachePreloader.shared.store
        store.setEntry(
            videoId: videoId,
            startOffset: 0,
            totalSize: 10_000_000,
            contentType: "video/mp4"
        )
        let chunk = Data(repeating: 0x55, count: CacheStore.chunkSize)
        _ = store.writeChunk(videoId: videoId, chunk: chunk)
        #expect(store.currentVideoId() == videoId)

        // Fire critical-level pressure.
        VideoCachePreloader.shared.handleMemoryPressure(event: .critical)

        #expect(store.currentVideoId() == nil, "critical must clear the store entirely")
        #expect(store.cacheStatus(videoId: videoId) == nil)
    }

    @Test func videoCache_readData_outOfRange_returnsNil() async {
        let payloadSize = 32 * 1024 // 32 KB
        let payload = Self.makePayload(size: payloadSize)
        Self.installMockResponding(with: payload)
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()

        let videoId = "vid-oob"
        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: videoId,
            url: URL(string: "https://ta.example.com/media/\(videoId).mp4")!,
            token: "test-token",
            startPosition: 0,
            duration: 0,
            maxRetries: 0
        )
        let finished = await Self.waitForPreloadComplete(videoId: videoId, expectedBytes: payloadSize)
        #expect(finished)

        // Offset past end -> nil.
        let past = await VideoCachePreloader.shared.readData(
            videoId: videoId,
            offset: Int64(payloadSize) + 1,
            length: 64
        )
        #expect(past == nil)

        // Offset at end (no bytes available) -> nil.
        let atEnd = await VideoCachePreloader.shared.readData(
            videoId: videoId,
            offset: Int64(payloadSize),
            length: 64
        )
        #expect(atEnd == nil)

        // Negative offset -> nil.
        let negative = await VideoCachePreloader.shared.readData(
            videoId: videoId,
            offset: -10,
            length: 64
        )
        #expect(negative == nil)

        // Unknown videoId -> nil even though the cache is populated.
        let wrongId = await VideoCachePreloader.shared.readData(
            videoId: "some-other-id",
            offset: 0,
            length: 64
        )
        #expect(wrongId == nil)

        await VideoCachePreloader.shared.clear()
    }

    /// Behavioural coverage for the HEAD-probe branch in `downloadVideo`
    /// (`startPosition > 0 && duration > 0`). Asserts that:
    /// 1. the GET request that follows the HEAD probe carries a `Range:`
    ///    header derived from the HEAD response's `Content-Length` and the
    ///    position fraction — proves the HEAD URLSession ran and supplied
    ///    `knownTotalSize`;
    /// 2. the resulting cache entry is stored at `startOffset == byteOffset`
    ///    — locks against a regression where the offset is computed for the
    ///    request but the entry is seeded at the wrong offset.
    @Test func preloader_headProbe_seeksByPositionFraction() async {
        let payloadSize = 200 * 1024 // 200 KB
        VideoCachePreloader.testSessionConfigurationOverride = MockResponse.makeConfiguration()
        let url = URL(string: "https://ta.example.com/media/vid-head.mp4")!

        // HEAD returns Content-Length only; GET responds 206 with empty body
        // (the test only inspects the request, not the cached bytes).
        MockURLProtocol.requestHandler = { request in
            if request.httpMethod == "HEAD" {
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "video/mp4",
                        "Content-Length": "\(payloadSize)"
                    ]
                )!
                return (response, Data())
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "video/mp4",
                    "Content-Range": "bytes 51200-\(payloadSize - 1)/\(payloadSize)"
                ]
            )!
            return (response, Data())
        }
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()

        // 25 % of 60 s -> byteOffset = 200 KB * 0.25 = 51200.
        let videoId = "vid-head"
        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: videoId,
            url: url,
            token: "test-token",
            startPosition: 15,
            duration: 60,
            maxRetries: 0
        )

        // Poll briefly: startPreloadWithRetry returns before the download
        // Task finishes setting lastRequest and seeding the cache entry.
        _ = await Self.pollUntil(timeoutSeconds: 2) {
            guard let last = MockURLProtocol.lastRequest,
                  last.httpMethod != "HEAD",
                  last.value(forHTTPHeaderField: "Range") != nil else {
                return false
            }
            return await VideoCachePreloader.shared.cacheStatus(videoId: videoId) != nil
        }

        let rangeHeader = MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Range")
        #expect(rangeHeader == "bytes=51200-",
                "expected Range header derived from HEAD-supplied Content-Length × (15/60); got \(rangeHeader ?? "nil")")

        // Locks the seek-stored-at-wrong-offset regression: a refactor that
        // computes `byteOffset` for the request but passes 0 to `setEntry`
        // would still pass the Range-header assertion above.
        let status = await VideoCachePreloader.shared.cacheStatus(videoId: videoId)
        #expect(status?.startOffset == 51200,
                "expected cache entry seeded at the HEAD-derived offset; got \(status?.startOffset.description ?? "nil")")

        await VideoCachePreloader.shared.clear()
    }
}
}
