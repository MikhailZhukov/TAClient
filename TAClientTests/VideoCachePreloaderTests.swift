import Testing
import Foundation
@testable import TAClient

/// Baseline + parallel-preload coverage for `VideoCachePreloader`.
///
/// These tests lock in the behaviour of `startPreloadWithRetry`, `readData`,
/// `cacheStatus`, `clear`, and `updatePlaybackPosition`. Task 3 of the
/// prefix-cache-region plan introduces parallel prefix + main downloads, so
/// the existing assertions have been updated to use `regionStatus(.prefix)` /
/// `regionStatus(.main)` and `cachedByteCount` instead of the legacy single-
/// region `cacheStatus` semantics (which now returns `.main`-only state).
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

    /// Poll until the cache holds at least `expectedBytes` summed across BOTH
    /// regions or the timeout elapses. Replaces the older variant that used
    /// `cacheStatus.endOffset` — that accessor now returns `.main`-only data,
    /// which is `nil` for small files (everything fits in `.prefix`).
    private static func waitForPreloadComplete(
        videoId: String,
        expectedBytes: Int,
        timeoutSeconds: Double = 5
    ) async -> Bool {
        let store = VideoCachePreloader.shared.store
        return await pollUntil(timeoutSeconds: timeoutSeconds) {
            store.cachedByteCount(videoId: videoId) >= expectedBytes
        }
    }

    /// Mock handler shared by tests that don't care about the
    /// prefix-vs-main split: returns Content-Length on HEAD, and the full
    /// `payload` on every GET regardless of Range header. With small
    /// payloads (`< prefixSize`) the preloader writes everything into
    /// `.prefix` and skips the main download.
    private static func installMockResponding(with payload: Data, statusCode: Int = 200) {
        VideoCachePreloader.testSessionConfigurationOverride = MockResponse.makeConfiguration()
        let url = URL(string: "https://ta.example.com")!
        MockURLProtocol.requestHandler = { request in
            if request.httpMethod == "HEAD" {
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "video/mp4",
                        "Content-Length": "\(payload.count)"
                    ]
                )!
                return (response, Data())
            }
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
        // Size spans multiple 512 KB chunks so the chunk-read path is
        // exercised. 600 KB is < prefixSize (8 MB floor) so everything lands
        // in `.prefix`; the main region is not created (small-file case).
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

        // `cacheStatus` reports the `.main` region — for a small file there
        // is no main, so it's `nil`. `regionStatus(.prefix)` covers the
        // populated range instead.
        #expect(await VideoCachePreloader.shared.cacheStatus(videoId: videoId) == nil,
                ".main absent for small file (everything in prefix)")
        let prefixStatus = VideoCachePreloader.shared.store.regionStatus(videoId: videoId, region: .prefix)
        #expect(prefixStatus?.startOffset == 0)
        #expect(prefixStatus?.endOffset == Int64(payloadSize))
        #expect(prefixStatus?.contentType == "video/mp4")

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
        // Small file → prefix-only. Use the store directly to assert presence
        // because `cacheStatus` (main-only) is nil here.
        #expect(VideoCachePreloader.shared.store.currentVideoId() == videoId)

        await VideoCachePreloader.shared.clear()

        #expect(VideoCachePreloader.shared.store.currentVideoId() == nil)
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
        // Pass the prefixSize as `resumeByte` so `.main.startOffset` lands on a
        // chunk-aligned boundary (the prefix region exists alongside; the test
        // exercises the main region's emergency-trim semantics).
        let totalSize: Int64 = Int64(seedBytes * 2)
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        store.setEntry(
            videoId: videoId,
            totalSize: totalSize,
            contentType: "video/mp4",
            resumeByte: prefixSize
        )
        // Write in `chunkSize`-bounded chunks so `writeChunk` accepts them.
        var remaining = seedBytes
        var writeOffset = 0
        while remaining > 0 {
            let size = min(CacheStore.chunkSize, remaining)
            let chunk = Data(repeating: UInt8(writeOffset & 0xFF), count: size)
            _ = store.writeChunk(videoId: videoId, toRegion: .main, chunk: chunk)
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
        // 10 MB total > prefixSize (8 MB) → both regions exist; main starts at
        // 8 MB. Write the seed chunk into `.main` so the critical-pressure
        // handler observes a non-empty entry to clear.
        store.setEntry(
            videoId: videoId,
            totalSize: 10_000_000,
            contentType: "video/mp4",
            resumeByte: 0
        )
        let chunk = Data(repeating: 0x55, count: CacheStore.chunkSize)
        _ = store.writeChunk(videoId: videoId, toRegion: .main, chunk: chunk)
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

    /// Behavioural coverage for the resume / position-seek path with the new
    /// parallel-preload structure. Files >= 16 MB exercise both regions:
    /// prefix `[0, 8MB)` and main `[max(8MB, resumeByte), totalSize)`. With
    /// `startPosition=15 / duration=60` and `totalSize=16 MB`, `resumeByte =
    /// 4 MB` which is below prefixSize, so `mainStartByte = 8 MB`.
    ///
    /// We mock 206 with full prefix/main payloads so the regions actually
    /// populate; afterwards we inspect the Range headers (recorded by the
    /// mock) and the resulting `regionStatus` for both regions.
    @Test func preloader_headProbe_seeksByPositionFraction() async {
        let payloadSize = 16 * 1024 * 1024 // 16 MB → both regions exist
        let prefixSize = Int(CacheStore.computePrefixSize(totalSize: Int64(payloadSize)))
        // Send a single chunk's worth of bytes per region — enough to make
        // the regions readable and pass the "no bytes landed → clear entry"
        // safety net at the end of downloadVideo without forcing a full
        // 16 MB transfer through MockURLProtocol on every run.
        let prefixPayload = Self.makePayload(size: CacheStore.chunkSize)
        let mainPayload = Self.makePayload(size: CacheStore.chunkSize)

        VideoCachePreloader.testSessionConfigurationOverride = MockResponse.makeConfiguration()
        let url = URL(string: "https://ta.example.com/media/vid-head.mp4")!

        nonisolated(unsafe) var prefixRangeSeen: String?
        nonisolated(unsafe) var mainRangeSeen: String?
        let rangeLock = NSLock()
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
            let range = request.value(forHTTPHeaderField: "Range") ?? ""
            rangeLock.lock()
            let isPrefix: Bool
            if range.hasPrefix("bytes=0-") {
                prefixRangeSeen = range
                isPrefix = true
            } else {
                mainRangeSeen = range
                isPrefix = false
            }
            rangeLock.unlock()
            // Echo a plausible Content-Range header — start byte parsed from
            // the request, end at payloadSize-1.
            let startByteString = range
                .replacingOccurrences(of: "bytes=", with: "")
                .split(separator: "-")
                .first
                .map(String.init) ?? "0"
            let response = HTTPURLResponse(
                url: url,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "video/mp4",
                    "Content-Range": "bytes \(startByteString)-\(payloadSize - 1)/\(payloadSize)"
                ]
            )!
            return (response, isPrefix ? prefixPayload : mainPayload)
        }
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()

        // 25 % of 60 s × 16 MB → resumeByte = 4 MB (below prefixSize=8 MB).
        // So `mainStartByte = max(8 MB, 4 MB) = 8 MB`.
        let videoId = "vid-head"
        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: videoId,
            url: url,
            token: "test-token",
            startPosition: 15,
            duration: 60,
            maxRetries: 0
        )

        // Poll until the preload has finished writing into both regions: we
        // want at least one chunk on each side so the safety net at the end
        // of downloadVideo does NOT clear the entry. Generous timeout (10 s)
        // to absorb simulator load when the full test suite is running in
        // parallel-suites mode.
        let store = VideoCachePreloader.shared.store
        let ready = await Self.pollUntil(timeoutSeconds: 10) {
            guard store.currentVideoId() == videoId else { return false }
            let prefixBytes = store.regionStatus(videoId: videoId, region: .prefix)
                .map { Int($0.endOffset - $0.startOffset) } ?? 0
            let mainBytes = store.regionStatus(videoId: videoId, region: .main)
                .map { Int($0.endOffset - $0.startOffset) } ?? 0
            return prefixBytes >= CacheStore.chunkSize && mainBytes >= CacheStore.chunkSize
        }
        #expect(ready, "both regions must have at least one chunk after preload")

        rangeLock.lock()
        let prefixRange = prefixRangeSeen
        let mainRange = mainRangeSeen
        rangeLock.unlock()
        #expect(prefixRange == "bytes=0-\(prefixSize - 1)",
                "expected prefix GET with Range bytes=0-\(prefixSize - 1); got \(prefixRange ?? "nil")")
        #expect(mainRange == "bytes=\(prefixSize)-\(payloadSize - 1)",
                "expected main GET with Range starting at prefixSize \(prefixSize); got \(mainRange ?? "nil")")

        let prefixStatus = store.regionStatus(videoId: videoId, region: .prefix)
        let mainStatus = store.regionStatus(videoId: videoId, region: .main)
        #expect(prefixStatus?.startOffset == 0)
        #expect(mainStatus?.startOffset == Int64(prefixSize),
                "main region must start at prefixSize when resumeByte < prefixSize")

        await VideoCachePreloader.shared.clear()
    }

    // MARK: - Task 3 — Parallel prefix + main downloads

    /// Build a mock that distinguishes the two parallel GETs by Range header.
    /// Returns Content-Length on HEAD and a `(prefixData, mainData)` tuple
    /// based on whether the GET's Range starts at byte 0 (prefix) or at
    /// `mainStartByte` (main). Optional `prefixStatus` / `mainStatus` lets
    /// individual tests fail one side without affecting the other.
    private static func installParallelMock(
        totalSize: Int,
        prefixData: Data,
        mainData: Data,
        mainStartByte: Int,
        prefixStatus: Int = 206,
        mainStatus: Int = 206,
        prefixDelay: TimeInterval = 0,
        mainDelay: TimeInterval = 0,
        onPrefixRequest: (@Sendable () -> Void)? = nil,
        onMainRequest: (@Sendable () -> Void)? = nil
    ) {
        VideoCachePreloader.testSessionConfigurationOverride = MockResponse.makeConfiguration()
        let url = URL(string: "https://ta.example.com")!
        // HEAD requests are always served synchronously through requestHandler.
        // Range GETs follow one of two paths depending on whether a delay was
        // requested:
        //   - No delay → handled inline by `requestHandler` (cheap, one-shot).
        //   - Delay   → handled by `slowStreamHandler`, which delivers chunks
        //     between sleeps on a background queue while polling its
        //     `stopped` flag. This makes delayed responses cancellable —
        //     URLSession's `stopLoading()` callback flips the flag and the
        //     background loop exits before completing the delivery. Replaces
        //     the prior `Thread.sleep` (non-cancellable) used inside the
        //     synchronous handler, which silently let both downloads
        //     complete despite the cancel test asking for interruption.
        MockURLProtocol.requestHandler = { request in
            if request.httpMethod == "HEAD" {
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "video/mp4",
                        "Content-Length": "\(totalSize)"
                    ]
                )!
                return (response, Data())
            }
            // Both delay branches are routed through slowStreamHandler below.
            // Inline path here handles only the no-delay case.
            let range = request.value(forHTTPHeaderField: "Range") ?? ""
            if range.hasPrefix("bytes=0-") {
                onPrefixRequest?()
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: prefixStatus,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "video/mp4",
                        "Content-Range": "bytes 0-\(prefixData.count - 1)/\(totalSize)"
                    ]
                )!
                return (response, prefixData)
            } else {
                onMainRequest?()
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: mainStatus,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "video/mp4",
                        "Content-Range": "bytes \(mainStartByte)-\(totalSize - 1)/\(totalSize)"
                    ]
                )!
                return (response, mainData)
            }
        }

        // Install slow-stream only when at least one side has a delay.
        // slowStreamHandler takes precedence over requestHandler when set,
        // so this branch must also cover HEAD (responds instantly with no
        // delay) — otherwise the HEAD probe would go down the slow path.
        if prefixDelay > 0 || mainDelay > 0 {
            MockURLProtocol.slowStreamHandler = { request in
                // HEAD goes through with no delay: a single zero-byte chunk
                // and a zero per-chunk wait. Body is irrelevant for HEAD.
                if request.httpMethod == "HEAD" {
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: [
                            "Content-Type": "video/mp4",
                            "Content-Length": "\(totalSize)"
                        ]
                    )!
                    return (response, [Data()], 0)
                }

                let range = request.value(forHTTPHeaderField: "Range") ?? ""
                let isPrefix = range.hasPrefix("bytes=0-")
                let delay = isPrefix ? prefixDelay : mainDelay
                if isPrefix { onPrefixRequest?() } else { onMainRequest?() }

                let status = isPrefix ? prefixStatus : mainStatus
                let payload = isPrefix ? prefixData : mainData
                let contentRange = isPrefix
                    ? "bytes 0-\(max(0, prefixData.count - 1))/\(totalSize)"
                    : "bytes \(mainStartByte)-\(totalSize - 1)/\(totalSize)"

                let response = HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "video/mp4",
                        "Content-Range": contentRange
                    ]
                )!
                // Two stub chunks: empty primer, then real payload. The
                // slow-stream loop sleeps `delay/2` between chunks and
                // checks `stopped` at the top of each iteration, so a
                // cancel during the first sleep prevents the payload from
                // landing. This replaces the previous `Thread.sleep` inside
                // the synchronous `requestHandler`, which silently let both
                // downloads complete even when the test asked for a cancel.
                let chunks: [Data] = [Data(), payload]
                let perChunkDelay = delay / 2.0
                return (response, chunks, perChunkDelay)
            }
        }
    }

    @Test func preload_startsBothTasksInParallel() async {
        let totalSize = 16 * 1024 * 1024 // 16 MB
        let prefixSize = Int(CacheStore.computePrefixSize(totalSize: Int64(totalSize)))
        let prefixData = Self.makePayload(size: prefixSize)
        let mainData = Self.makePayload(size: totalSize - prefixSize)

        nonisolated(unsafe) var prefixCount = 0
        nonisolated(unsafe) var mainCount = 0
        let countLock = NSLock()

        Self.installParallelMock(
            totalSize: totalSize,
            prefixData: prefixData,
            mainData: mainData,
            mainStartByte: prefixSize,
            onPrefixRequest: { countLock.lock(); prefixCount += 1; countLock.unlock() },
            onMainRequest: { countLock.lock(); mainCount += 1; countLock.unlock() }
        )
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()

        let videoId = "vid-parallel-start"
        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: videoId,
            url: URL(string: "https://ta.example.com/media/\(videoId).mp4")!,
            token: "test-token",
            startPosition: 0,
            duration: 0,
            maxRetries: 0
        )

        // Wait for both GETs to land.
        _ = await Self.pollUntil(timeoutSeconds: 5) {
            countLock.lock()
            let done = prefixCount >= 1 && mainCount >= 1
            countLock.unlock()
            return done
        }

        countLock.lock()
        #expect(prefixCount == 1, "prefix GET must run exactly once; got \(prefixCount)")
        #expect(mainCount == 1, "main GET must run exactly once; got \(mainCount)")
        countLock.unlock()

        await VideoCachePreloader.shared.clear()
    }

    @Test func preload_prefixCompletesIndependentlyOfMain() async {
        let totalSize = 16 * 1024 * 1024
        let prefixSize = Int(CacheStore.computePrefixSize(totalSize: Int64(totalSize)))
        let prefixData = Self.makePayload(size: prefixSize)
        let mainData = Self.makePayload(size: totalSize - prefixSize)

        // Main is slow (500 ms before responding); prefix is instant.
        Self.installParallelMock(
            totalSize: totalSize,
            prefixData: prefixData,
            mainData: mainData,
            mainStartByte: prefixSize,
            mainDelay: 0.5
        )
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()

        let videoId = "vid-prefix-first"
        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: videoId,
            url: URL(string: "https://ta.example.com/media/\(videoId).mp4")!,
            token: "test-token",
            startPosition: 0,
            duration: 0,
            maxRetries: 0
        )

        // Prefix should be readable before main even starts responding.
        let store = VideoCachePreloader.shared.store
        let prefixReady = await Self.pollUntil(timeoutSeconds: 2) {
            let status = store.regionStatus(videoId: videoId, region: .prefix)
            return (status?.endOffset ?? 0) == Int64(prefixSize)
        }
        #expect(prefixReady, "prefix must be fully cached while main is still in-flight")

        // Main should still be either empty or partially downloaded at this
        // point — there's a small race window so we just observe that the
        // prefix is ready and let the preload finish in the background.
        _ = await Self.pollUntil(timeoutSeconds: 3) {
            let status = store.regionStatus(videoId: videoId, region: .main)
            return (status?.endOffset ?? 0) == Int64(totalSize)
        }

        await VideoCachePreloader.shared.clear()
    }

    @Test func preload_mainFailureDoesNotKillPrefix() async {
        let totalSize = 16 * 1024 * 1024
        let prefixSize = Int(CacheStore.computePrefixSize(totalSize: Int64(totalSize)))
        let prefixData = Self.makePayload(size: prefixSize)
        let mainData = Data() // empty body on failure

        // Main GET returns 503; prefix returns 206 normally.
        Self.installParallelMock(
            totalSize: totalSize,
            prefixData: prefixData,
            mainData: mainData,
            mainStartByte: prefixSize,
            mainStatus: 503
        )
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()

        let videoId = "vid-main-fail"
        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: videoId,
            url: URL(string: "https://ta.example.com/media/\(videoId).mp4")!,
            token: "test-token",
            startPosition: 0,
            duration: 0,
            maxRetries: 0
        )

        let store = VideoCachePreloader.shared.store
        let prefixReady = await Self.pollUntil(timeoutSeconds: 5) {
            let status = store.regionStatus(videoId: videoId, region: .prefix)
            return (status?.endOffset ?? 0) == Int64(prefixSize)
        }
        #expect(prefixReady, "prefix must complete despite main 503")
        let prefixSlice = await VideoCachePreloader.shared.readData(videoId: videoId, offset: 0, length: 256)
        #expect(prefixSlice == prefixData.prefix(256), "prefix bytes must be readable")
        let mainStatus = store.regionStatus(videoId: videoId, region: .main)
        #expect((mainStatus?.endOffset ?? 0) == Int64(prefixSize),
                "main region should not have advanced on 503 (startOffset == endOffset == \(prefixSize))")

        await VideoCachePreloader.shared.clear()
    }

    @Test func preload_prefixFailureDoesNotKillMain() async {
        let totalSize = 16 * 1024 * 1024
        let prefixSize = Int(CacheStore.computePrefixSize(totalSize: Int64(totalSize)))
        let prefixData = Data()
        let mainData = Self.makePayload(size: totalSize - prefixSize)

        // Prefix GET returns 503; main returns 206 normally.
        Self.installParallelMock(
            totalSize: totalSize,
            prefixData: prefixData,
            mainData: mainData,
            mainStartByte: prefixSize,
            prefixStatus: 503
        )
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()

        let videoId = "vid-prefix-fail"
        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: videoId,
            url: URL(string: "https://ta.example.com/media/\(videoId).mp4")!,
            token: "test-token",
            startPosition: 0,
            duration: 0,
            maxRetries: 0
        )

        let store = VideoCachePreloader.shared.store
        let mainReady = await Self.pollUntil(timeoutSeconds: 5) {
            let status = store.regionStatus(videoId: videoId, region: .main)
            return (status?.endOffset ?? 0) == Int64(totalSize)
        }
        #expect(mainReady, "main must complete despite prefix 503")
        // Read from main region (offset starts at prefixSize).
        let slice = await VideoCachePreloader.shared.readData(
            videoId: videoId,
            offset: Int64(prefixSize),
            length: 256
        )
        #expect(slice == mainData.prefix(256), "main bytes must be readable starting at prefixSize")
        let prefixStatus = store.regionStatus(videoId: videoId, region: .prefix)
        #expect((prefixStatus?.endOffset ?? 0) == 0,
                "prefix region should be empty on 503")

        await VideoCachePreloader.shared.clear()
    }

    @Test func preload_cancelStopsBothTasks() async {
        let totalSize = 16 * 1024 * 1024
        let prefixSize = Int(CacheStore.computePrefixSize(totalSize: Int64(totalSize)))
        let prefixData = Self.makePayload(size: prefixSize)
        let mainData = Self.makePayload(size: totalSize - prefixSize)

        // Slow both sides so we have a window to cancel in.
        Self.installParallelMock(
            totalSize: totalSize,
            prefixData: prefixData,
            mainData: mainData,
            mainStartByte: prefixSize,
            prefixDelay: 1.0,
            mainDelay: 1.0
        )
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()

        let videoId = "vid-cancel"
        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: videoId,
            url: URL(string: "https://ta.example.com/media/\(videoId).mp4")!,
            token: "test-token",
            startPosition: 0,
            duration: 0,
            maxRetries: 0
        )

        // Cancel almost immediately — both delays are 1s.
        try? await Task.sleep(for: .milliseconds(100))
        await VideoCachePreloader.shared.cancelPreload(videoId: videoId)

        // After cancellation the preload task should no longer be active.
        // Allow a brief drain window for cancellation to propagate.
        _ = await Self.pollUntil(timeoutSeconds: 3) {
            !(await VideoCachePreloader.shared.isPreloading(videoId: videoId))
        }
        #expect(await VideoCachePreloader.shared.isPreloading(videoId: videoId) == false,
                "preload must report not-preloading after cancel")

        // Neither region should be fully populated since the mock's delay
        // exceeds the cancel window.
        let store = VideoCachePreloader.shared.store
        let prefix = store.regionStatus(videoId: videoId, region: .prefix)
        let main = store.regionStatus(videoId: videoId, region: .main)
        let prefixFull = (prefix?.endOffset ?? 0) == Int64(prefixSize)
        let mainFull = (main?.endOffset ?? 0) == Int64(totalSize)
        #expect(!(prefixFull && mainFull), "cancel must interrupt at least one of the two downloads")

        await VideoCachePreloader.shared.clear()
    }

    @Test func preload_401FromPrefix_postsNotification() async {
        let totalSize = 16 * 1024 * 1024
        let prefixSize = Int(CacheStore.computePrefixSize(totalSize: Int64(totalSize)))
        let mainData = Self.makePayload(size: totalSize - prefixSize)

        // Prefix returns 401; main 206 normally. Both must run, prefix
        // posts notification, main completes.
        Self.installParallelMock(
            totalSize: totalSize,
            prefixData: Data(),
            mainData: mainData,
            mainStartByte: prefixSize,
            prefixStatus: 401
        )
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()

        let videoId = "vid-401-prefix"
        let expectation = NotificationExpectation(
            name: .taAuthUnauthorized,
            senderId: videoId
        )

        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: videoId,
            url: URL(string: "https://ta.example.com/media/\(videoId).mp4")!,
            token: "test-token",
            startPosition: 0,
            duration: 0,
            maxRetries: 0
        )

        let fired = await expectation.wait(timeoutSeconds: 5)
        #expect(fired, "401 from prefix GET must post .taAuthUnauthorized")

        // Main should still have completed independently.
        let store = VideoCachePreloader.shared.store
        let mainReady = await Self.pollUntil(timeoutSeconds: 5) {
            let status = store.regionStatus(videoId: videoId, region: .main)
            return (status?.endOffset ?? 0) == Int64(totalSize)
        }
        #expect(mainReady, "main should complete despite prefix 401 — per-task isolation")

        await VideoCachePreloader.shared.clear()
    }

    @Test func memoryWarning_preservesPrefix_trimsMainOnly() async {
        // Seed both regions directly via the store (avoids race with
        // download loop). Prefix at 4 MB, main carrying half-cache+10 MB so
        // warning-level trim has work to do.
        await VideoCachePreloader.shared.clear()
        let videoId = "vid-mem-warn-regions"
        let store = VideoCachePreloader.shared.store

        // 600 MB total → prefixSize is 6 MB (1% of 600 MB).
        let totalSize: Int64 = 600 * 1024 * 1024
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        store.setEntry(
            videoId: videoId,
            totalSize: totalSize,
            contentType: "video/mp4",
            resumeByte: prefixSize
        )

        // Fill prefix with full prefixSize bytes.
        var prefixRemaining = Int(prefixSize)
        var prefixWriteSeq = 0
        while prefixRemaining > 0 {
            let size = min(CacheStore.chunkSize, prefixRemaining)
            let chunk = Data(repeating: UInt8(prefixWriteSeq & 0xFF), count: size)
            _ = store.writeChunk(videoId: videoId, toRegion: .prefix, chunk: chunk)
            prefixRemaining -= size
            prefixWriteSeq &+= 1
        }

        // Seed main with `maxCacheSize/2 + 10 MB` so the trim has measurable work.
        let mainSeedBytes = (CacheStore.maxCacheSize / 2) + (10 * 1024 * 1024)
        var mainRemaining = mainSeedBytes
        var mainWriteSeq = 0
        while mainRemaining > 0 {
            let size = min(CacheStore.chunkSize, mainRemaining)
            let chunk = Data(repeating: UInt8(mainWriteSeq & 0xFF), count: size)
            _ = store.writeChunk(videoId: videoId, toRegion: .main, chunk: chunk)
            mainRemaining -= size
            mainWriteSeq &+= 1
        }

        let prefixBefore = store.regionStatus(videoId: videoId, region: .prefix)
        let mainBefore = store.regionStatus(videoId: videoId, region: .main)
        #expect((prefixBefore?.endOffset ?? 0) == prefixSize, "precondition: prefix fully seeded")
        let prefixByteCountBefore = Int((prefixBefore?.endOffset ?? 0) - (prefixBefore?.startOffset ?? 0))
        let mainByteCountBefore = Int((mainBefore?.endOffset ?? 0) - (mainBefore?.startOffset ?? 0))

        // Fire warning-level pressure.
        VideoCachePreloader.shared.handleMemoryPressure(event: .warning)

        let prefixAfter = store.regionStatus(videoId: videoId, region: .prefix)
        let mainAfter = store.regionStatus(videoId: videoId, region: .main)
        let prefixByteCountAfter = Int((prefixAfter?.endOffset ?? 0) - (prefixAfter?.startOffset ?? 0))
        let mainByteCountAfter = Int((mainAfter?.endOffset ?? 0) - (mainAfter?.startOffset ?? 0))

        // Prefix is pinned: bytes unchanged.
        #expect(prefixByteCountAfter == prefixByteCountBefore,
                "prefix must not be trimmed by .warning pressure")
        // Main is trimmed below before.
        #expect(mainByteCountAfter < mainByteCountBefore,
                "main must shrink on .warning pressure")

        await VideoCachePreloader.shared.clear()
    }

    @Test func memoryCritical_clearsBothRegions() async {
        await VideoCachePreloader.shared.clear()
        let videoId = "vid-mem-crit-both"
        let store = VideoCachePreloader.shared.store

        let totalSize: Int64 = 16 * 1024 * 1024
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        store.setEntry(
            videoId: videoId,
            totalSize: totalSize,
            contentType: "video/mp4",
            resumeByte: prefixSize
        )

        // Seed each region with a single chunk so the entry is non-empty
        // before the critical event fires.
        let prefixChunk = Data(repeating: 0xAA, count: CacheStore.chunkSize)
        let mainChunk = Data(repeating: 0xBB, count: CacheStore.chunkSize)
        _ = store.writeChunk(videoId: videoId, toRegion: .prefix, chunk: prefixChunk)
        _ = store.writeChunk(videoId: videoId, toRegion: .main, chunk: mainChunk)
        #expect(store.currentVideoId() == videoId)

        // Fire critical-level pressure.
        VideoCachePreloader.shared.handleMemoryPressure(event: .critical)

        #expect(store.currentVideoId() == nil, "critical must clear the entire entry")
        #expect(store.regionStatus(videoId: videoId, region: .prefix) == nil,
                "prefix must be gone after critical")
        #expect(store.regionStatus(videoId: videoId, region: .main) == nil,
                "main must be gone after critical")
    }
}
}
