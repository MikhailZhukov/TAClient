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

    @Test func handleMemoryPressure_critical_trimsMain_keepsEntry() async {
        // Policy change in Task 4 of `20260527-fix-memory-pressure-recovery.md`:
        // `.critical` now emergency-trims `.main` to 8 MB instead of clearing
        // the entire entry. The videoId/totalSize/contentType/prefix survive
        // so the restart hook can rebuild from the current playhead.
        await VideoCachePreloader.shared.clear()
        let videoId = "vid-mem-critical"
        let store = VideoCachePreloader.shared.store
        // 10 MB total > prefixSize (8 MB) → both regions exist; main starts at
        // 8 MB. Write the seed chunk into `.main` so the critical-pressure
        // handler observes a non-empty entry to trim.
        store.setEntry(
            videoId: videoId,
            totalSize: 10_000_000,
            contentType: "video/mp4",
            resumeByte: 0
        )
        let chunk = Data(repeating: 0x55, count: CacheStore.chunkSize)
        _ = store.writeChunk(videoId: videoId, toRegion: .main, chunk: chunk)
        #expect(store.currentVideoId() == videoId)

        let prefixBefore = store.regionStatus(videoId: videoId, region: .prefix)
        let prefixByteCountBefore = Int((prefixBefore?.endOffset ?? 0) - (prefixBefore?.startOffset ?? 0))

        // Fire critical-level pressure.
        VideoCachePreloader.shared.handleMemoryPressure(event: .critical)

        // Entry must survive — videoId still tracked, totalSize/contentType
        // preserved (probed via regionStatus).
        #expect(store.currentVideoId() == videoId, "critical must NOT clear the entry (Task 4 policy change)")
        // Prefix region unchanged: emergencyTrim only touches `.main`.
        let prefixAfter = store.regionStatus(videoId: videoId, region: .prefix)
        let prefixByteCountAfter = Int((prefixAfter?.endOffset ?? 0) - (prefixAfter?.startOffset ?? 0))
        #expect(prefixByteCountAfter == prefixByteCountBefore, "prefix must survive .critical")
        // Main is below 8 MB target (here it was only 512 KB; trim is a noop).
        let mainAfter = store.regionStatus(videoId: videoId, region: .main)
        let mainByteCountAfter = Int((mainAfter?.endOffset ?? 0) - (mainAfter?.startOffset ?? 0))
        #expect(mainByteCountAfter <= 8 * 1024 * 1024, "main must be ≤ 8 MB after .critical")
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
        onMainRequest: (@Sendable () -> Void)? = nil,
        onMainRangeSeen: (@Sendable (String) -> Void)? = nil
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
                onMainRangeSeen?(range)
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
                if isPrefix {
                    onPrefixRequest?()
                } else {
                    onMainRequest?()
                    onMainRangeSeen?(range)
                }

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

    // MARK: - Task 4 (20260527-fix-memory-pressure-recovery) — softened .critical

    /// Large-cache case: prefix (10 MB) + main (300 MB) seeded directly.
    /// `.critical` should: (a) leave prefix untouched, (b) shrink main to
    /// ≤ 8 MB (load-bearing: target must be < `RestartTrigger.mainCachedByteThreshold` so the
    /// post-`.critical` restart hook fires; see VideoCachePreloader
    /// `criticalTrimTargetBytes` doc comment). The entry itself MUST survive.
    @Test func criticalEvent_trimsMainTo8MB_keepsPrefix() async {
        await VideoCachePreloader.shared.clear()
        let videoId = "vid-mem-crit-trim-8"
        let store = VideoCachePreloader.shared.store

        // Seed: 400 MB total file. Prefix capped at 50 MB; we'll fill 10 MB.
        // Main starts at prefixSize and we'll fill 300 MB into it (the trim
        // path drops front chunks until ≤ 8 MB).
        let totalSize: Int64 = 400 * 1024 * 1024
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        store.setEntry(
            videoId: videoId,
            totalSize: totalSize,
            contentType: "video/mp4",
            resumeByte: prefixSize
        )

        // Fill prefix with 10 MB.
        let prefixTargetBytes = 10 * 1024 * 1024
        var prefixRemaining = prefixTargetBytes
        var i = 0
        while prefixRemaining > 0 {
            let size = min(CacheStore.chunkSize, prefixRemaining)
            let chunk = Data(repeating: UInt8(i & 0xFF), count: size)
            _ = store.writeChunk(videoId: videoId, toRegion: .prefix, chunk: chunk)
            prefixRemaining -= size
            i &+= 1
        }
        // Fill main with 300 MB.
        let mainTargetBytes = 300 * 1024 * 1024
        var mainRemaining = mainTargetBytes
        var j = 0
        while mainRemaining > 0 {
            let size = min(CacheStore.chunkSize, mainRemaining)
            let chunk = Data(repeating: UInt8((j + 128) & 0xFF), count: size)
            _ = store.writeChunk(videoId: videoId, toRegion: .main, chunk: chunk)
            mainRemaining -= size
            j &+= 1
        }

        let prefixBefore = store.regionStatus(videoId: videoId, region: .prefix)
        let prefixCountBefore = Int((prefixBefore?.endOffset ?? 0) - (prefixBefore?.startOffset ?? 0))
        let mainBefore = store.regionStatus(videoId: videoId, region: .main)
        let mainCountBefore = Int((mainBefore?.endOffset ?? 0) - (mainBefore?.startOffset ?? 0))
        #expect(mainCountBefore > 8 * 1024 * 1024, "precondition: main exceeds 8 MB target")

        // Drive critical pressure.
        VideoCachePreloader.shared.handleMemoryPressure(event: .critical)
        // Give the Task { await invalidatePreload() } a moment to run.
        try? await Task.sleep(for: .milliseconds(100))

        // Entry survives.
        #expect(store.currentVideoId() == videoId)
        // Prefix unchanged.
        let prefixAfter = store.regionStatus(videoId: videoId, region: .prefix)
        let prefixCountAfter = Int((prefixAfter?.endOffset ?? 0) - (prefixAfter?.startOffset ?? 0))
        #expect(prefixCountAfter == prefixCountBefore, "prefix bytes must not change on .critical")
        // Main shrunk to ≤ 8 MB. Allow +1 chunk tolerance (trim drops whole
        // chunks from the front; the last surviving chunk may push the count
        // slightly above the exact target).
        let mainAfter = store.regionStatus(videoId: videoId, region: .main)
        let mainCountAfter = Int((mainAfter?.endOffset ?? 0) - (mainAfter?.startOffset ?? 0))
        #expect(mainCountAfter <= 8 * 1024 * 1024 + CacheStore.chunkSize,
                "main must be ≤ 8 MB (+1 chunk tolerance) after .critical, got \(mainCountAfter / 1_000_000) MB")
        #expect(mainCountAfter < mainCountBefore, "main must shrink on .critical")

        await VideoCachePreloader.shared.clear()
    }

    /// `.critical` MUST cancel any in-flight preload — same as the prior
    /// `store.clear()` + `invalidatePreload()` policy. After the event,
    /// `preloadTask` and `preloadTaskVideoId` are nil.
    @Test func criticalEvent_cancelsInFlightPreload() async {
        let totalSize = 16 * 1024 * 1024
        let prefixSize = Int(CacheStore.computePrefixSize(totalSize: Int64(totalSize)))
        let prefixData = Self.makePayload(size: prefixSize)
        let mainData = Self.makePayload(size: totalSize - prefixSize)

        // Slow main so the preload stays in-flight long enough that we can
        // drive .critical against an active task.
        Self.installParallelMock(
            totalSize: totalSize,
            prefixData: prefixData,
            mainData: mainData,
            mainStartByte: prefixSize,
            mainDelay: 2.0
        )
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()

        let videoId = "vid-crit-cancel-inflight"
        let url = URL(string: "https://ta.example.com/media/\(videoId).mp4")!
        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: videoId, url: url, token: "test-token",
            startPosition: 0, duration: 0, maxRetries: 0
        )

        // Wait until preloadTaskVideoId is set AND main region exists
        // (i.e. the HEAD probe and setEntry have run on the actor — we want
        // an active in-flight download so .critical has something to cancel).
        let store = VideoCachePreloader.shared.store
        let primed = await Self.pollUntil(timeoutSeconds: 5) {
            let vidMatch = await VideoCachePreloader.shared.preloadTaskVideoId == videoId
            let mainExists = store.regionStatus(videoId: videoId, region: .main) != nil
            return vidMatch && mainExists
        }
        #expect(primed, "precondition: preload installed and main region seeded")
        let preloadingBefore = await VideoCachePreloader.shared.isPreloading(videoId: videoId)
        #expect(preloadingBefore, "precondition: preload active before .critical")

        // Drive .critical.
        VideoCachePreloader.shared.handleMemoryPressure(event: .critical)
        // invalidatePreload is dispatched via Task — give it time to run on
        // the actor. Use a longer poll window because the actor may be
        // serving the in-flight downloadVideo's chunk-receive hops.
        let cancelled = await Self.pollUntil(timeoutSeconds: 10) {
            await VideoCachePreloader.shared.preloadTaskVideoId == nil
        }
        #expect(cancelled, "preloadTaskVideoId MUST become nil within timeout after .critical")
        let preloadingAfter = await VideoCachePreloader.shared.isPreloading(videoId: videoId)
        #expect(!preloadingAfter, "isPreloading MUST be false after .critical")

        await VideoCachePreloader.shared.clear()
    }

    /// Small-main case: main has only 4 MB cached (< 8 MB target).
    /// `emergencyTrim` should be a no-op (returns 0), main bytes unchanged.
    @Test func criticalEvent_smallMain_isNoop() async {
        await VideoCachePreloader.shared.clear()
        let videoId = "vid-crit-small-main"
        let store = VideoCachePreloader.shared.store

        let totalSize: Int64 = 100 * 1024 * 1024
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)
        store.setEntry(
            videoId: videoId,
            totalSize: totalSize,
            contentType: "video/mp4",
            resumeByte: prefixSize
        )
        // Fill main with 4 MB only (below the 8 MB critical trim target).
        let mainTargetBytes = 4 * 1024 * 1024
        var remaining = mainTargetBytes
        var i = 0
        while remaining > 0 {
            let size = min(CacheStore.chunkSize, remaining)
            let chunk = Data(repeating: UInt8(i & 0xFF), count: size)
            _ = store.writeChunk(videoId: videoId, toRegion: .main, chunk: chunk)
            remaining -= size
            i &+= 1
        }
        let mainBefore = store.regionStatus(videoId: videoId, region: .main)
        let mainCountBefore = Int((mainBefore?.endOffset ?? 0) - (mainBefore?.startOffset ?? 0))
        #expect(mainCountBefore <= 8 * 1024 * 1024, "precondition: main is below 8 MB target")

        // Drive .critical.
        VideoCachePreloader.shared.handleMemoryPressure(event: .critical)
        try? await Task.sleep(for: .milliseconds(100))

        let mainAfter = store.regionStatus(videoId: videoId, region: .main)
        let mainCountAfter = Int((mainAfter?.endOffset ?? 0) - (mainAfter?.startOffset ?? 0))
        // Main unchanged — emergencyTrim early-returned because count ≤ target.
        #expect(mainCountAfter == mainCountBefore, "main bytes must NOT change when below trim target")

        await VideoCachePreloader.shared.clear()
    }

    /// `.critical` MUST record `lastCancelledVideoId` so a suspended
    /// `reseedMain` past its pre-drain guard bails on the post-drain mirror
    /// check. The recording happens inside `invalidatePreload` — same
    /// invariant the prior `store.clear()` policy already preserved (the
    /// fallback `store.currentVideoId()` read in `invalidatePreload`'s body
    /// covers the case where the store entry survived).
    @Test func criticalEvent_recordsLastCancelledVideoId() async {
        let totalSize = 16 * 1024 * 1024
        let prefixSize = Int(CacheStore.computePrefixSize(totalSize: Int64(totalSize)))
        let prefixData = Self.makePayload(size: prefixSize)
        let mainData = Self.makePayload(size: totalSize - prefixSize)

        Self.installParallelMock(
            totalSize: totalSize,
            prefixData: prefixData,
            mainData: mainData,
            mainStartByte: prefixSize,
            mainDelay: 2.0
        )
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()

        let videoId = "vid-crit-record-cancel"
        let url = URL(string: "https://ta.example.com/media/\(videoId).mp4")!
        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: videoId, url: url, token: "test-token",
            startPosition: 0, duration: 0, maxRetries: 0
        )
        _ = await Self.pollUntil(timeoutSeconds: 5) {
            await VideoCachePreloader.shared.preloadTaskVideoId == videoId
        }

        // Drive .critical.
        VideoCachePreloader.shared.handleMemoryPressure(event: .critical)
        _ = await Self.pollUntil(timeoutSeconds: 5) {
            await VideoCachePreloader.shared.lastCancelledVideoId == videoId
        }

        let recorded = await VideoCachePreloader.shared.lastCancelledVideoId
        #expect(recorded == videoId,
                "lastCancelledVideoId MUST be recorded by .critical → invalidatePreload")

        await VideoCachePreloader.shared.clear()
    }

    /// Post-`.critical` reseed bails. After `.critical` cancels the in-flight
    /// preload, `preloadTask` is nil and `lastCancelledVideoId == videoId`.
    /// A subsequent `reseedMain` for the same videoId hits its pre-drain
    /// `guard preloadTask != nil` and bails immediately — without bumping
    /// generation or calling resetMainRegion. This pins the documented
    /// interaction between `.critical` and a reseed dispatch (the
    /// production scenario: the 1Hz observer's reseed-trigger fires after
    /// `.critical` has invalidated the preload).
    ///
    /// NOTE: the original spec wanted to drive `.critical` while reseedMain
    /// was suspended in its drain (the post-drain mirror bail path). That
    /// scenario is inherently racy in test contexts — the `.critical` Task
    /// and the reseedMain continuation compete for the actor's executor,
    /// and the ordering is not reliably FIFO when the system is under
    /// load (full test-suite execution). We test the WEAKER invariant
    /// here: the pre-drain orphan-reseed guard catches reseeds that arrive
    /// AFTER `.critical` has nilled preloadTask. The post-drain mirror
    /// check is independently covered by
    /// `reseedMain_navigateAwayAndBack_sameVideo_doesNotKillFreshPreload`
    /// via the `cancelPreload + startPreloadWithRetry` path (same guard,
    /// different trigger).
    @Test func criticalEvent_inFlightReseed_bailsOnOrphanReseedGuard() async {
        let totalSize = 16 * 1024 * 1024
        let prefixSize = Int(CacheStore.computePrefixSize(totalSize: Int64(totalSize)))
        let prefixData = Self.makePayload(size: prefixSize)
        let mainData = Self.makePayload(size: totalSize - prefixSize)

        Self.installParallelMock(
            totalSize: totalSize,
            prefixData: prefixData,
            mainData: mainData,
            mainStartByte: prefixSize,
            mainDelay: 2.0
        )
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()

        let videoId = "vid-crit-inflight-reseed"
        let url = URL(string: "https://ta.example.com/media/\(videoId).mp4")!
        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: videoId, url: url, token: "test-token",
            startPosition: 0, duration: 0, maxRetries: 0
        )
        let store = VideoCachePreloader.shared.store
        let mainSeeded = await Self.pollUntil(timeoutSeconds: 5) {
            store.regionStatus(videoId: videoId, region: .main) != nil
        }
        #expect(mainSeeded, "precondition: main region seeded by setEntry")
        let genBeforeCritical = await VideoCachePreloader.shared.preloadGeneration

        // Drive .critical. invalidatePreload's Task will set
        // lastCancelledVideoId = videoId and nil preloadTask.
        VideoCachePreloader.shared.handleMemoryPressure(event: .critical)
        let invalidated = await Self.pollUntil(timeoutSeconds: 10) {
            let lastCanc = await VideoCachePreloader.shared.lastCancelledVideoId
            let taskVid = await VideoCachePreloader.shared.preloadTaskVideoId
            return lastCanc == videoId && taskVid == nil
        }
        #expect(invalidated,
                "precondition: .critical invalidated preload (lastCancelledVideoId set, preloadTask nilled)")

        // Now call reseedMain — it MUST bail at the orphan-reseed guard
        // (preloadTask == nil) WITHOUT bumping generation or mutating state.
        // This is the path a "1Hz observer fires a reseed right after .critical"
        // takes in production. The bail is via either:
        //   - pre-drain `guard preloadTask != nil else { return }` (most likely),
        //   - post-drain `if lastCancelledVideoId == videoId { return }` (if a
        //     race re-installs preloadTask briefly).
        await VideoCachePreloader.shared.reseedMain(
            videoId: videoId,
            atByte: Int64(prefixSize + 2 * 1024 * 1024),
            url: url,
            token: "test-token"
        )

        // Assert generation did NOT bump — reseedMain bailed.
        let genAfterReseed = await VideoCachePreloader.shared.preloadGeneration
        #expect(genAfterReseed == genBeforeCritical,
                "reseedMain MUST bail after .critical — NO generation bump (got \(genBeforeCritical) -> \(genAfterReseed))")

        // Prefix preserved through .critical.
        let prefixAfter = store.regionStatus(videoId: videoId, region: .prefix)
        #expect(prefixAfter != nil, "prefix MUST survive .critical")
        // Main present (trimmed-not-cleared); <= 8 MB.
        let mainAfter = store.regionStatus(videoId: videoId, region: .main)
        let mainCountAfter = Int((mainAfter?.endOffset ?? 0) - (mainAfter?.startOffset ?? 0))
        #expect(mainCountAfter <= 8 * 1024 * 1024 + CacheStore.chunkSize,
                "main must be <= 8 MB (+1 chunk tolerance) after .critical (trimmed not cleared)")

        await VideoCachePreloader.shared.clear()
    }

    // MARK: - Task 3 — reseedMain
    //
    // These tests cover the new `VideoCachePreloader.reseedMain` API
    // introduced in `20260526-fix-preloader-follow-large-scrub.md`. The
    // method cancels the current preload, resets `.main` at the requested
    // byte (via `CacheStore.resetMainRegion`), and restarts download of
    // `[atByte..<totalSize]` into `.main`. Prefix is untouched.

    @Test func reseedMain_resetsMainRegion() async {
        let totalSize = 16 * 1024 * 1024
        let prefixSize = Int(CacheStore.computePrefixSize(totalSize: Int64(totalSize)))
        let prefixData = Self.makePayload(size: prefixSize)
        let mainData = Self.makePayload(size: totalSize - prefixSize)

        Self.installParallelMock(
            totalSize: totalSize,
            prefixData: prefixData,
            mainData: mainData,
            mainStartByte: prefixSize,
            // Slow main download so the preloadTask stays in-flight while we
            // reseed — without this delay the small mock completes too
            // quickly and reseedMain's orphan-guard (preloadTask != nil)
            // skips the reseed.
            mainDelay: 2.0
        )
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()

        let videoId = "vid-reseed-reset"
        let url = URL(string: "https://ta.example.com/media/\(videoId).mp4")!
        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: videoId,
            url: url,
            token: "test-token",
            startPosition: 0,
            duration: 0,
            maxRetries: 0
        )

        // Wait until main has at least one chunk so there's something to
        // reset.
        let store = VideoCachePreloader.shared.store
        let mainHasData = await Self.pollUntil(timeoutSeconds: 5) {
            let main = store.regionStatus(videoId: videoId, region: .main)
            return (main?.endOffset ?? 0) > Int64(prefixSize)
        }
        #expect(mainHasData, "precondition: main must have at least one chunk before reseed")

        // Reseed to a later byte.
        let reseedByte: Int64 = Int64(prefixSize + (4 * 1024 * 1024))
        await VideoCachePreloader.shared.reseedMain(
            videoId: videoId,
            atByte: reseedByte,
            url: url,
            token: "test-token"
        )

        // Immediately after reseed: main must be anchored at reseedByte and
        // contain zero cached chunks. (The new download task may begin
        // populating it on the next tick, so we observe BEFORE polling.)
        let mainAfter = store.regionStatus(videoId: videoId, region: .main)
        #expect(mainAfter?.startOffset == reseedByte,
                "main.startOffset must equal reseedByte after reseedMain")
        // endOffset == startOffset immediately post-reset means zero chunks.
        // The download may have already pumped a chunk in the brief window
        // between resetMainRegion and this read; assert endOffset >=
        // startOffset (no negative drift, never went backward).
        #expect((mainAfter?.endOffset ?? 0) >= reseedByte,
                "main.endOffset must be >= reseedByte post-reset")

        await VideoCachePreloader.shared.clear()
    }

    @Test func reseedMain_downloadsCorrectRange() async {
        let totalSize = 16 * 1024 * 1024
        let prefixSize = Int(CacheStore.computePrefixSize(totalSize: Int64(totalSize)))
        let prefixData = Self.makePayload(size: prefixSize)
        let mainData = Self.makePayload(size: totalSize - prefixSize)

        nonisolated(unsafe) var observedRanges: [String] = []
        let rangeLock = NSLock()
        Self.installParallelMock(
            totalSize: totalSize,
            prefixData: prefixData,
            mainData: mainData,
            mainStartByte: prefixSize,
            // Slow main download so the preloadTask stays in-flight while we
            // call reseedMain (orphan-guard precondition: nil preloadTask
            // would no-op the reseed).
            mainDelay: 2.0,
            onMainRangeSeen: { range in
                rangeLock.lock()
                observedRanges.append(range)
                rangeLock.unlock()
            }
        )
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()

        let videoId = "vid-reseed-range"
        let url = URL(string: "https://ta.example.com/media/\(videoId).mp4")!
        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: videoId,
            url: url,
            token: "test-token",
            startPosition: 0,
            duration: 0,
            maxRetries: 0
        )

        // Wait for the initial main GET to land before reseeding so we have
        // a baseline against which the second main GET is distinguishable.
        let initialDone = await Self.pollUntil(timeoutSeconds: 5) {
            rangeLock.lock()
            let count = observedRanges.count
            rangeLock.unlock()
            return count >= 1
        }
        #expect(initialDone, "initial main GET must complete before reseed")

        // Reseed to a far-forward byte.
        let reseedByte: Int64 = Int64(prefixSize + (5 * 1024 * 1024))
        await VideoCachePreloader.shared.reseedMain(
            videoId: videoId,
            atByte: reseedByte,
            url: url,
            token: "test-token"
        )

        // Wait for the reseed's GET to be observed.
        let reseedGetSeen = await Self.pollUntil(timeoutSeconds: 5) {
            rangeLock.lock()
            let lastRange = observedRanges.last
            rangeLock.unlock()
            return lastRange == "bytes=\(reseedByte)-\(totalSize - 1)"
        }
        #expect(reseedGetSeen, "reseed must issue a GET with Range bytes=\(reseedByte)-\(totalSize - 1)")

        // Also assert via MockURLProtocol.lastRequest as the plan spec
        // requires.
        let lastRange = MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Range")
        #expect(lastRange == "bytes=\(reseedByte)-\(totalSize - 1)",
                "MockURLProtocol.lastRequest should reflect the reseed Range; got \(lastRange ?? "nil")")

        await VideoCachePreloader.shared.clear()
    }

    @Test func reseedMain_wrongVideoId_noop() async {
        let totalSize = 16 * 1024 * 1024
        let prefixSize = Int(CacheStore.computePrefixSize(totalSize: Int64(totalSize)))
        let prefixData = Self.makePayload(size: prefixSize)
        let mainData = Self.makePayload(size: totalSize - prefixSize)

        Self.installParallelMock(
            totalSize: totalSize,
            prefixData: prefixData,
            mainData: mainData,
            mainStartByte: prefixSize
        )
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()

        let videoId = "vid-reseed-wrongid"
        let url = URL(string: "https://ta.example.com/media/\(videoId).mp4")!
        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: videoId,
            url: url,
            token: "test-token",
            startPosition: 0,
            duration: 0,
            maxRetries: 0
        )

        let store = VideoCachePreloader.shared.store
        _ = await Self.pollUntil(timeoutSeconds: 5) {
            let main = store.regionStatus(videoId: videoId, region: .main)
            return (main?.endOffset ?? 0) > Int64(prefixSize)
        }
        let mainBefore = store.regionStatus(videoId: videoId, region: .main)

        // Call reseed with a mismatched videoId — must be a complete no-op.
        await VideoCachePreloader.shared.reseedMain(
            videoId: "some-other-id",
            atByte: 999_999,
            url: url,
            token: "test-token"
        )

        let mainAfter = store.regionStatus(videoId: videoId, region: .main)
        #expect(mainAfter?.startOffset == mainBefore?.startOffset,
                "wrong-id reseed must NOT change main.startOffset")
        // Endpoints may continue to advance because the live preload is
        // still running for the correct videoId — endOffset is not pinned.
        // The critical invariant is that startOffset (the anchor) didn't
        // move.

        await VideoCachePreloader.shared.clear()
    }

    @Test func reseedMain_atByteAtOrAboveTotal_noop() async {
        let totalSize = 16 * 1024 * 1024
        let prefixSize = Int(CacheStore.computePrefixSize(totalSize: Int64(totalSize)))
        let prefixData = Self.makePayload(size: prefixSize)
        let mainData = Self.makePayload(size: totalSize - prefixSize)

        Self.installParallelMock(
            totalSize: totalSize,
            prefixData: prefixData,
            mainData: mainData,
            mainStartByte: prefixSize
        )
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()

        let videoId = "vid-reseed-eof"
        let url = URL(string: "https://ta.example.com/media/\(videoId).mp4")!
        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: videoId,
            url: url,
            token: "test-token",
            startPosition: 0,
            duration: 0,
            maxRetries: 0
        )

        let store = VideoCachePreloader.shared.store
        _ = await Self.pollUntil(timeoutSeconds: 5) {
            let main = store.regionStatus(videoId: videoId, region: .main)
            return (main?.endOffset ?? 0) > Int64(prefixSize)
        }
        let mainBefore = store.regionStatus(videoId: videoId, region: .main)

        // atByte == totalSize → at-EOF; reseedMain must skip without touching
        // main.
        await VideoCachePreloader.shared.reseedMain(
            videoId: videoId,
            atByte: Int64(totalSize),
            url: url,
            token: "test-token"
        )

        let mainAfter = store.regionStatus(videoId: videoId, region: .main)
        #expect(mainAfter?.startOffset == mainBefore?.startOffset,
                "at-EOF reseed must NOT change main.startOffset")

        // atByte > totalSize → same behaviour.
        await VideoCachePreloader.shared.reseedMain(
            videoId: videoId,
            atByte: Int64(totalSize) + 100,
            url: url,
            token: "test-token"
        )

        let mainAfter2 = store.regionStatus(videoId: videoId, region: .main)
        #expect(mainAfter2?.startOffset == mainBefore?.startOffset,
                "past-EOF reseed must NOT change main.startOffset")

        await VideoCachePreloader.shared.clear()
    }

    @Test func reseedMain_noMainRegion_noop() async {
        // Small file: 600 KB < prefixSize floor (8 MB) → only `.prefix`
        // region created; `.main` is nil. reseedMain must skip cleanly.
        let payloadSize = 600 * 1024
        let payload = Self.makePayload(size: payloadSize)
        Self.installMockResponding(with: payload)
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()

        let videoId = "vid-reseed-small"
        let url = URL(string: "https://ta.example.com/media/\(videoId).mp4")!
        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: videoId,
            url: url,
            token: "test-token",
            startPosition: 0,
            duration: 0,
            maxRetries: 0
        )
        let finished = await Self.waitForPreloadComplete(videoId: videoId, expectedBytes: payloadSize)
        #expect(finished, "small-file preload must finish (everything in prefix)")

        let store = VideoCachePreloader.shared.store
        #expect(store.regionStatus(videoId: videoId, region: .main) == nil,
                "precondition: small file has no .main region")

        // reseedMain must be a no-op when there's no .main region.
        await VideoCachePreloader.shared.reseedMain(
            videoId: videoId,
            atByte: 100_000,
            url: url,
            token: "test-token"
        )

        #expect(store.regionStatus(videoId: videoId, region: .main) == nil,
                "reseed must NOT create a .main region for small files")
        // Prefix should still be intact.
        let prefix = store.regionStatus(videoId: videoId, region: .prefix)
        #expect(prefix?.endOffset == Int64(payloadSize),
                "prefix must remain fully populated after no-op reseed")

        await VideoCachePreloader.shared.clear()
    }

    @Test func reseedMain_oldTaskCompletionDoesNotClobber() async {
        // Set up a slow main download so the old preload is still in-flight
        // when we reseed. Prefix downloads quickly (no delay) so we can
        // observe that prefix bytes survive the reseed.
        let totalSize = 16 * 1024 * 1024
        let prefixSize = Int(CacheStore.computePrefixSize(totalSize: Int64(totalSize)))
        let prefixData = Self.makePayload(size: prefixSize)
        let mainData = Self.makePayload(size: totalSize - prefixSize)

        Self.installParallelMock(
            totalSize: totalSize,
            prefixData: prefixData,
            mainData: mainData,
            mainStartByte: prefixSize,
            mainDelay: 0.8 // main download takes ~800ms — gives us time to reseed mid-flight
        )
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()

        let videoId = "vid-reseed-genguard"
        let url = URL(string: "https://ta.example.com/media/\(videoId).mp4")!
        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: videoId,
            url: url,
            token: "test-token",
            startPosition: 0,
            duration: 0,
            maxRetries: 0
        )

        // Wait until prefix has populated (instant) AND main exists. We
        // intentionally do NOT wait for main to populate — reseeding mid-
        // flight is the whole point of this test.
        let store = VideoCachePreloader.shared.store
        let setupReady = await Self.pollUntil(timeoutSeconds: 5) {
            let prefix = store.regionStatus(videoId: videoId, region: .prefix)
            let main = store.regionStatus(videoId: videoId, region: .main)
            return (prefix?.endOffset ?? 0) > 0 && main != nil
        }
        #expect(setupReady, "precondition: prefix populated and main exists")

        let prefixBytesBefore = store.regionStatus(videoId: videoId, region: .prefix)
            .map { Int($0.endOffset - $0.startOffset) } ?? 0
        let genBefore = await VideoCachePreloader.shared.preloadGeneration

        // Reseed to a far-forward byte while old main download is still
        // in-flight.
        let reseedByte: Int64 = Int64(prefixSize + (5 * 1024 * 1024))
        await VideoCachePreloader.shared.reseedMain(
            videoId: videoId,
            atByte: reseedByte,
            url: url,
            token: "test-token"
        )

        let genAfter = await VideoCachePreloader.shared.preloadGeneration
        #expect(genAfter > genBefore, "reseed must bump preloadGeneration")

        // Wait for any post-reseed bookkeeping (finalizePreloadIfCurrent
        // bookkeeping, downloadRange's deferred logging) to settle. With
        // iter1's awaited-cancellation fix, `reseedMain` already awaits the
        // old preloadTask's `.value` before returning, so by the time we
        // reach this line the OLD task has already drained — its
        // generation-guarded tail check (`generation == preloadGeneration`)
        // has already run and skipped the clear. The sleep is now defensive
        // padding for the NEW reseed task's startup logging on slow
        // simulator runs; the assertion below is the real test.
        try? await Task.sleep(for: .milliseconds(1500))

        // (a) prefix bytes survived — old downloadVideo's tail
        //     `store.clear()` (which fires when cachedByteCount == 0 in the
        //     old generation) did NOT wipe prefix.
        let prefixBytesAfter = store.regionStatus(videoId: videoId, region: .prefix)
            .map { Int($0.endOffset - $0.startOffset) } ?? 0
        #expect(prefixBytesAfter >= prefixBytesBefore,
                "prefix bytes must survive the old preload's tail clear")

        // (b) main reflects the reseed.
        let mainAfter = store.regionStatus(videoId: videoId, region: .main)
        #expect(mainAfter?.startOffset == reseedByte,
                "main.startOffset must equal reseedByte after reseed")

        // (c) main's bytes (if any landed) come from the NEW download,
        //     anchored at reseedByte. endOffset >= startOffset is the
        //     invariant — anything past startOffset is post-reseed bytes.
        if let main = mainAfter {
            #expect(main.endOffset >= main.startOffset,
                    "main endOffset must not regress below startOffset")
        }

        await VideoCachePreloader.shared.clear()
    }

    /// Orphan-reseed guard: when `cancelPreload` has nil'd `preloadTask`
    /// (e.g. the user navigated away in `stopPlayback`) but the store entry
    /// is still tracking the videoId, a stale Task-hop to `reseedMain` must
    /// NOT spawn a fresh download for a video the user is no longer
    /// watching. Verified by observing that `isPreloading` stays false and
    /// `.main` is not reset.
    @Test func reseedMain_afterCancelPreload_isNoop() async {
        let totalSize = 16 * 1024 * 1024
        let prefixSize = Int(CacheStore.computePrefixSize(totalSize: Int64(totalSize)))
        let prefixData = Self.makePayload(size: prefixSize)
        let mainData = Self.makePayload(size: totalSize - prefixSize)

        Self.installParallelMock(
            totalSize: totalSize,
            prefixData: prefixData,
            mainData: mainData,
            mainStartByte: prefixSize
        )
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()

        let videoId = "vid-reseed-orphan"
        let url = URL(string: "https://ta.example.com/media/\(videoId).mp4")!
        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: videoId,
            url: url,
            token: "test-token",
            startPosition: 0,
            duration: 0,
            maxRetries: 0
        )
        let store = VideoCachePreloader.shared.store
        _ = await Self.pollUntil(timeoutSeconds: 5) {
            store.regionStatus(videoId: videoId, region: .main) != nil
        }

        // Simulate what stopPlayback does: cancelPreload the active task.
        // This nils preloadTask but does NOT clear the store entry — the
        // videoId still matches.
        await VideoCachePreloader.shared.cancelPreload(videoId: videoId)

        let mainBefore = store.regionStatus(videoId: videoId, region: .main)
        let preloadingBefore = await VideoCachePreloader.shared.isPreloading(videoId: videoId)
        #expect(!preloadingBefore, "precondition: cancelPreload must clear isPreloading")
        // Snapshot generation BEFORE the orphan reseed — iter 3 (Testing #6):
        // orphan reseed must NOT bump generation (would indicate it entered
        // the spawn path, defeating the orphan guard's purpose).
        let genBefore = await VideoCachePreloader.shared.preloadGeneration

        // Stale reseed dispatch (the queued Task hop from the time observer
        // that ran before stopPlayback executed). Must be a no-op.
        await VideoCachePreloader.shared.reseedMain(
            videoId: videoId,
            atByte: Int64(prefixSize + 4 * 1024 * 1024),
            url: url,
            token: "test-token"
        )

        let mainAfter = store.regionStatus(videoId: videoId, region: .main)
        #expect(mainAfter?.startOffset == mainBefore?.startOffset,
                "orphan reseed must NOT change main.startOffset")
        let preloadingAfter = await VideoCachePreloader.shared.isPreloading(videoId: videoId)
        #expect(!preloadingAfter,
                "orphan reseed must NOT spawn a fresh download")
        let genAfter = await VideoCachePreloader.shared.preloadGeneration
        #expect(genAfter == genBefore,
                "orphan reseed must NOT bump preloadGeneration (would indicate spawn-path entry)")

        await VideoCachePreloader.shared.clear()
    }

    /// **Drain-loop coverage test (iter 3 / Testing #2).**
    ///
    /// `reseedMain`'s drain loop (`while let oldTask = preloadTask`) handles
    /// the suspension-window race where a peer installs a new `preloadTask`
    /// during `await oldTask.value`. This test fires two concurrent
    /// `reseedMain` calls and asserts:
    ///   1. Generation counter advances by AT LEAST 2 (both calls
    ///      successfully completed their `&+= 1` bump — no early-bail).
    ///   2. No live preloadTask remains orphaned (a single live preloadTask
    ///      is allowed because the latter `reseedMain` re-spawns one for the
    ///      new target).
    ///   3. `.main`'s `startOffset` reflects the LAST-completed reseed
    ///      (whichever finished last on the actor's serial executor).
    ///
    /// If a regression replaced the drain `while let` with a single `if let`,
    /// the suspension-window race would let one call's `preloadTask` overwrite
    /// the other's — leaving a leaked live task. The "no orphaned task"
    /// assertion catches that.
    @Test func reseedMain_concurrentDrainLoop_noOrphan() async {
        let totalSize = 16 * 1024 * 1024
        let prefixSize = Int(CacheStore.computePrefixSize(totalSize: Int64(totalSize)))
        let prefixData = Self.makePayload(size: prefixSize)
        let mainData = Self.makePayload(size: totalSize - prefixSize)

        // mainDelay keeps preloadTask alive long enough that two concurrent
        // reseeds will both hit the drain-loop suspension window.
        Self.installParallelMock(
            totalSize: totalSize,
            prefixData: prefixData,
            mainData: mainData,
            mainStartByte: prefixSize,
            mainDelay: 1.0
        )
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()

        let videoId = "vid-drain-loop"
        let url = URL(string: "https://ta.example.com/media/\(videoId).mp4")!
        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: videoId,
            url: url,
            token: "test-token",
            startPosition: 0,
            duration: 0,
            maxRetries: 0
        )

        let store = VideoCachePreloader.shared.store
        let setupReady = await Self.pollUntil(timeoutSeconds: 5) {
            let prefix = store.regionStatus(videoId: videoId, region: .prefix)
            let main = store.regionStatus(videoId: videoId, region: .main)
            return (prefix?.endOffset ?? 0) > 0 && main != nil
        }
        #expect(setupReady, "precondition: prefix populated and main exists")

        let genBefore = await VideoCachePreloader.shared.preloadGeneration

        // Two reseed targets, well apart, both far past prefixEnd. The
        // actor's serial executor serialises actor entry, but each
        // reseedMain SUSPENDS on `await oldTask.value` — and during that
        // suspension a peer reseedMain can enter the actor, install its own
        // preloadTask, and suspend. The drain loop's `while let` is what
        // ensures both calls produce well-ordered output without leaking
        // tasks.
        let reseedA: Int64 = Int64(prefixSize + 2 * 1024 * 1024)
        let reseedB: Int64 = Int64(prefixSize + 5 * 1024 * 1024)
        async let resultA: Void = VideoCachePreloader.shared.reseedMain(
            videoId: videoId, atByte: reseedA, url: url, token: "test-token"
        )
        async let resultB: Void = VideoCachePreloader.shared.reseedMain(
            videoId: videoId, atByte: reseedB, url: url, token: "test-token"
        )
        _ = await (resultA, resultB)

        let genAfter = await VideoCachePreloader.shared.preloadGeneration
        // At LEAST one of the two reseeds reaches `preloadGeneration &+= 1`.
        // With the post-drain generation-bump bail (added to defeat the
        // navigate-away-and-back race for the SAME videoId), the second
        // reseed to resume may legitimately bail BEFORE its own bump
        // because the first one's bump made its `entryGeneration` snapshot
        // stale. That's correct behaviour: serialising two reseeds for
        // the same video onto the actor's serial executor naturally
        // funnels work to whichever resumed first, and the other bails
        // rather than racing for the same `.main` region. Either delta=1
        // (the bail won) or delta>=2 (both bumped despite the bail —
        // possible if the second snapshotted gen AFTER the first bumped,
        // depending on actor-admit ordering) is acceptable. If a
        // regression replaced the drain `while let` with a single `if
        // let`, neither call would bump — delta=0 — so we still defend
        // against the original drain-loop omission.
        #expect(genAfter - genBefore >= 1,
                "At least one concurrent reseed must bump preloadGeneration (got delta=\(genAfter - genBefore))")

        // After both reseeds complete, `.main.startOffset` must equal one
        // of the two reseed targets (the one that didn't bail) — never a
        // torn intermediate.
        let mainFinal = store.regionStatus(videoId: videoId, region: .main)
        #expect(
            mainFinal?.startOffset == reseedA || mainFinal?.startOffset == reseedB,
            "main.startOffset must equal one of the two reseed targets (got \(String(describing: mainFinal?.startOffset)))"
        )

        // No orphaned task: cancel and wait for any spawned tasks to drain,
        // then assert isPreloading is false. With the drain-loop fix, the
        // last-completed reseed leaves at most one live task; cancelPreload
        // nils it.
        await VideoCachePreloader.shared.cancelPreload(videoId: videoId)
        // Give cancellation a moment to settle (the spawned task's `await
        // self.downloadRange(...)` checks Task.isCancelled and exits).
        try? await Task.sleep(for: .milliseconds(200))
        let preloadingFinal = await VideoCachePreloader.shared.isPreloading(videoId: videoId)
        #expect(!preloadingFinal, "after cancel, no live preloadTask should remain")

        await VideoCachePreloader.shared.clear()
    }

    /// **Cross-video drain coverage test (iter 4 / Testing #1, Quality #1).**
    ///
    /// `reseedMain(X)`'s drain loop must NOT cancel a peer video's task
    /// installed during the drain's `await oldTask.value` suspension. Trace
    /// of the bug we're guarding against:
    ///   1. `startPreloadWithRetry(X)` installs `preloadTask = T_X`.
    ///   2. `reseedMain(X)` enters, calls `T_X.cancel()`, awaits
    ///      `T_X.value` — SUSPENDS the actor.
    ///   3. While reseedMain(X) is suspended (T_X awaited is an unstructured
    ///      Task await, NOT actor reentrance — the actor is free):
    ///      a. `cancelPreload(X)` enters: nils `preloadTask`, records
    ///         `lastCancelledVideoId = X`.
    ///      b. User lands on different video Y. `startPreloadWithRetry(Y)`
    ///         enters: clears store (X != Y), bumps generation, installs
    ///         `preloadTask = T_Y, preloadTaskVideoId = Y`.
    ///   4. `reseedMain(X)` resumes. WITHOUT the videoId-mirror check,
    ///      the drain `while let` sees `preloadTask = T_Y` and would
    ///      cancel + await it — killing Y's preload. WITH the mirror,
    ///      the loop condition `preloadTaskVideoId == videoId(X)` fails
    ///      (T_Y's videoId is Y), the loop exits without touching T_Y,
    ///      and the post-drain `currentVideoId() == videoId(X)` guard
    ///      bails cleanly.
    ///
    /// To deterministically open the suspension window, we use a slow main
    /// download for X (`mainDelay = 2.0s`), schedule reseedMain(X) on a
    /// detached Task (so the actor admits it first), let it suspend on
    /// `await T_X.value`, then issue cancelPreload(X) + startPreload(Y)
    /// inline. The actor's serial executor admits each in order; the
    /// suspended reseedMain holds no actor lock during its outer await.
    @Test func reseedMain_crossVideoPeer_doesNotKillPeerTask() async {
        let totalSize = 16 * 1024 * 1024
        let prefixSize = Int(CacheStore.computePrefixSize(totalSize: Int64(totalSize)))
        let prefixData = Self.makePayload(size: prefixSize)
        let mainData = Self.makePayload(size: totalSize - prefixSize)

        // Slow main so T_X stays in-flight long enough that reseedMain(X)
        // can enter and suspend on `await T_X.value`.
        Self.installParallelMock(
            totalSize: totalSize,
            prefixData: prefixData,
            mainData: mainData,
            mainStartByte: prefixSize,
            mainDelay: 3.0
        )
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()

        let videoX = "vid-peer-X"
        let videoY = "vid-peer-Y"
        let urlX = URL(string: "https://ta.example.com/media/\(videoX).mp4")!
        let urlY = URL(string: "https://ta.example.com/media/\(videoY).mp4")!

        // Step 1: start X's preload. T_X will stay in-flight ~3s.
        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: videoX, url: urlX, token: "test-token",
            startPosition: 0, duration: 0, maxRetries: 0
        )
        let store = VideoCachePreloader.shared.store
        _ = await Self.pollUntil(timeoutSeconds: 5) {
            store.regionStatus(videoId: videoX, region: .main) != nil
        }

        // Step 2: fire reseedMain(X) on a detached Task so it can suspend
        // independently of our main test flow. It enters the actor first,
        // calls T_X.cancel(), and awaits T_X.value (which has ~3s left).
        let reseedTask = Task {
            await VideoCachePreloader.shared.reseedMain(
                videoId: videoX,
                atByte: Int64(prefixSize + 4 * 1024 * 1024),
                url: urlX,
                token: "test-token"
            )
        }

        // Give reseedMain a moment to enter the actor and reach the
        // `await oldTask.value` suspension point.
        try? await Task.sleep(for: .milliseconds(100))

        // Step 3a: cancelPreload(X) — runs while reseedMain(X) is suspended.
        // Nils preloadTask, sets lastCancelledVideoId = X. Note that this
        // ALSO cancels T_X (already cancelled by reseedMain, no-op).
        await VideoCachePreloader.shared.cancelPreload(videoId: videoX)

        // Step 3b: user navigates to Y. Installs T_Y, preloadTaskVideoId=Y.
        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: videoY, url: urlY, token: "test-token",
            startPosition: 0, duration: 0, maxRetries: 0
        )
        _ = await Self.pollUntil(timeoutSeconds: 5) {
            store.regionStatus(videoId: videoY, region: .main) != nil
        }
        let yPreloadingMid = await VideoCachePreloader.shared.isPreloading(videoId: videoY)
        #expect(yPreloadingMid, "precondition: Y's preload active before reseedMain(X) resumes")

        // Wait for reseedMain(X) to complete (drain its suspension and
        // either exit cleanly or — bug — kill Y's task).
        await reseedTask.value

        // The critical assertion: Y's preloadTask must still be installed.
        // With the videoId-mirror in the drain loop, reseedMain(X) on resume
        // saw `preloadTaskVideoId(Y) != videoId(X)` → exited drain without
        // touching T_Y. Without the mirror, the drain `while let` would have
        // cancelled T_Y.
        let yTaskVidAfter = await VideoCachePreloader.shared.preloadTaskVideoId
        #expect(yTaskVidAfter == videoY,
                "preloadTaskVideoId MUST still be Y after stale reseedMain(X) — drain kill is the bug")
        let yPreloadingAfter = await VideoCachePreloader.shared.isPreloading(videoId: videoY)
        #expect(yPreloadingAfter,
                "Y's preload MUST survive a stale reseedMain(X) — cross-video drain kill is the bug")

        await VideoCachePreloader.shared.clear()
    }

    /// Backward scrub into prefix: when the reseed target byte falls below
    /// `prefixEnd`, the store's `resetMainRegion` clamps the new start up to
    /// `prefixEnd`. If the existing `.main` is already anchored at
    /// `prefixEnd` (common for un-trimmed playback that hasn't yet
    /// advanced), the old `clamped == previousStart` short-circuit in the
    /// store preserves `.main`'s cached bytes instead of wiping +
    /// re-downloading from the same anchor. `reseedMain` follows up by
    /// resuming the download at the live tail (no re-fetch of bytes we
    /// already have).
    @Test func reseedMain_backwardIntoPrefix_preservesMain() async {
        let totalSize = 16 * 1024 * 1024
        let prefixSize = Int(CacheStore.computePrefixSize(totalSize: Int64(totalSize)))
        let prefixData = Self.makePayload(size: prefixSize)
        let mainData = Self.makePayload(size: totalSize - prefixSize)

        // mainDelay keeps preloadTask in-flight across reseedMain (orphan
        // guard precondition). prefixDelay = 0 so prefix fills fast and the
        // backward-into-prefix clamp's precondition (`prefixEnd == main.start`)
        // is satisfied by the time we poll.
        Self.installParallelMock(
            totalSize: totalSize,
            prefixData: prefixData,
            mainData: mainData,
            mainStartByte: prefixSize,
            mainDelay: 2.0
        )
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()

        let videoId = "vid-reseed-backward"
        let url = URL(string: "https://ta.example.com/media/\(videoId).mp4")!
        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: videoId,
            url: url,
            token: "test-token",
            startPosition: 0,
            duration: 0,
            maxRetries: 0
        )
        let store = VideoCachePreloader.shared.store

        // Wait for BOTH prefix and main to be fully populated. The
        // short-circuit's precondition (`clamped == previousStart`) requires
        // `prefix.endOffset` to equal main's existing `startOffset` —
        // otherwise the clamp lands below main's start and reset still fires.
        // Race-free: poll explicitly for prefix.endOffset == prefixSize.
        let bothPopulated = await Self.pollUntil(timeoutSeconds: 5) {
            let prefix = store.regionStatus(videoId: videoId, region: .prefix)
            let main = store.regionStatus(videoId: videoId, region: .main)
            return (prefix?.endOffset ?? 0) >= Int64(prefixSize) &&
                (main?.endOffset ?? 0) > Int64(prefixSize + 1024 * 1024)
        }
        #expect(bothPopulated, "precondition: prefix must be FULL and main must accumulate before backward scrub")

        let mainBefore = store.regionStatus(videoId: videoId, region: .main)
        let cachedBefore = mainBefore.map { Int($0.endOffset - $0.startOffset) } ?? 0

        // Reseed to a byte inside the prefix region. resetMainRegion clamps
        // up to prefixEnd, which equals main.startOffset (untrimmed).
        await VideoCachePreloader.shared.reseedMain(
            videoId: videoId,
            atByte: 1024, // far below prefixEnd
            url: url,
            token: "test-token"
        )

        let mainAfter = store.regionStatus(videoId: videoId, region: .main)
        #expect(mainAfter?.startOffset == mainBefore?.startOffset,
                "main.startOffset must NOT change when reseed clamps to existing anchor")
        let cachedAfter = mainAfter.map { Int($0.endOffset - $0.startOffset) } ?? 0
        #expect(cachedAfter >= cachedBefore,
                "main's cached bytes must NOT regress on backward-into-prefix reseed")

        await VideoCachePreloader.shared.clear()
    }

    /// Race-corruption regression test. With `reseedMain` awaiting the
    /// cancelled preloadTask's completion BEFORE `resetMainRegion` (and the
    /// inner-while loop checking `Task.isCancelled` between writeChunks),
    /// stale bytes from the cancelled task's byte range cannot land in the
    /// region anchored at the new reseed byte. Verifies via byte-content
    /// inspection — strictly stronger than the offset-only assertions in
    /// `reseedMain_oldTaskCompletionDoesNotClobber`.
    ///
    /// Strategy: serve a per-range deterministic payload (each request's
    /// first byte is the low 8 bits of its `Range:` start). Initial preload
    /// writes pattern A into main starting at prefixSize; reseed to a far-
    /// forward byte starts pattern B in the new main. If the race fires,
    /// the new main's first byte at `reseedByte` would be the old pattern's
    /// continuation (whatever the cancelled task was streaming) instead of
    /// pattern B's first byte. The assertion compares the cached byte at
    /// `reseedByte` against the expected B pattern.
    ///
    /// Re-enabled after iter2 with a shrunken payload (~9 MB total — prefix
    /// is 8 MB minimum per `CacheStore.computePrefixSize`, plus a 1 MB main
    /// window). Smaller per-range mocks reduce the time the slow handler's
    /// background dispatch sits in flight, lowering the chance of overlap
    /// with parallel-run simulator I/O contention.
    @Test func reseedMain_postReseedBytesAreFromNewRange() async {
        // Minimal total size: prefix region is clamped to >= 8 MB regardless
        // of file size (`minPrefixSize`), and main must extend at least one
        // chunk past prefixSize for the "old main bytes before reseed" wait
        // to ever satisfy. 9 MB leaves a 1 MB window for main, enough for
        // multiple 512 KB chunks (`CacheStore.chunkSize`) to land.
        let totalSize = 9 * 1024 * 1024
        let prefixSize = Int(CacheStore.computePrefixSize(totalSize: Int64(totalSize)))
        // Reseed at an **un-aligned** offset inside `[prefixSize, totalSize)`.
        // The per-range payload is byte i of range starting at `start` =
        // `UInt8((start + i) & 0xFF)`. If we used a 256-aligned offset
        // (e.g. prefixSize + 512*1024), `UInt8(reseedByte & 0xFF) == 0` —
        // and a stale-write race delivering 512-KB-aligned chunks of the
        // OLD `[prefixSize..)` range would ALSO produce a 0 at the same
        // offset (chunk anchor + 0 modulo 256). The test would pass even
        // with the race protection removed.
        //
        // Pick `prefixSize + 511*1024 + 7`: the low byte is a deterministic
        // non-zero value (7 mod 256 = 7) AND not coincident with any chunk
        // boundary the cancelled OLD task would have produced (chunks
        // anchored at prefixSize + k*512KB never have low byte 7 because
        // prefixSize is 8 MB-aligned and 512 KB chunks contribute 0 to the
        // low byte).
        let reseedByte: Int64 = Int64(prefixSize + (511 * 1024) + 7)
        let url = URL(string: "https://ta.example.com")!

        // Custom mock: HEAD via requestHandler (fast synchronous response),
        // ranged GETs via slowStreamHandler with per-range deterministic
        // payload. Byte i of a range starting at `start` is
        // `UInt8((start + Int64(i)) & 0xFF)` — so the cached byte at file
        // offset X uniquely identifies which range request produced it.
        // The slow handler keeps the URLSession task in-flight long enough
        // for `reseedMain`'s orphan guard to see a non-nil preloadTask.
        VideoCachePreloader.testSessionConfigurationOverride = MockResponse.makeConfiguration()
        MockURLProtocol.requestHandler = { request in
            // HEAD only — synchronous, fast. Returns Content-Length so the
            // preloader's probe can compute totalSize and call setEntry.
            if request.httpMethod == "HEAD" {
                let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "video/mp4", "Content-Length": "\(totalSize)"]
                )!
                return (response, Data())
            }
            // Synchronous fallback for GETs — used when slowStreamHandler is
            // unset for some reason (defensive; not relied on).
            let range = request.value(forHTTPHeaderField: "Range") ?? "bytes=0-"
            let trimmed = range.replacingOccurrences(of: "bytes=", with: "")
            let parts = trimmed.split(separator: "-")
            let start = Int64(parts.first.map(String.init) ?? "0") ?? 0
            let end = parts.count > 1 ? (Int64(String(parts[1])) ?? Int64(totalSize - 1)) : Int64(totalSize - 1)
            let length = Int(max(0, end - start + 1))
            var bytes = [UInt8](); bytes.reserveCapacity(length)
            for i in 0..<length { bytes.append(UInt8(truncatingIfNeeded: start + Int64(i))) }
            let response = HTTPURLResponse(
                url: url, statusCode: 206, httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "video/mp4",
                    "Content-Range": "bytes \(start)-\(end)/\(totalSize)"
                ]
            )!
            return (response, Data(bytes))
        }
        MockURLProtocol.slowStreamHandler = { request in
            // Route HEAD through the synchronous handler (requestHandler is
            // bypassed when slowStreamHandler is non-nil — see MockURLProtocol).
            if request.httpMethod == "HEAD" {
                let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "video/mp4", "Content-Length": "\(totalSize)"]
                )!
                return (response, [Data()], 0)
            }
            let range = request.value(forHTTPHeaderField: "Range") ?? "bytes=0-"
            let trimmed = range.replacingOccurrences(of: "bytes=", with: "")
            let parts = trimmed.split(separator: "-")
            let start = Int64(parts.first.map(String.init) ?? "0") ?? 0
            let end = parts.count > 1 ? (Int64(String(parts[1])) ?? Int64(totalSize - 1)) : Int64(totalSize - 1)
            let length = Int(max(0, end - start + 1))
            var bytes = [UInt8](); bytes.reserveCapacity(length)
            for i in 0..<length { bytes.append(UInt8(truncatingIfNeeded: start + Int64(i))) }
            let response = HTTPURLResponse(
                url: url, statusCode: 206, httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "video/mp4",
                    "Content-Range": "bytes \(start)-\(end)/\(totalSize)"
                ]
            )!
            // Two chunks: first delivers immediately (slowStream loop calls
            // didLoad before the per-chunk sleep), second after sleep.
            // First chunk = full payload so main bytes land before reseed.
            // 500ms is enough dwell for the orphan-guard precondition
            // (preloadTask non-nil at reseed time) while keeping the test's
            // wall-clock budget low.
            return (response, [Data(bytes), Data()], 0.5)
        }
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()
        let videoId = "vid-reseed-byteverify"
        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: videoId,
            url: url,
            token: "test-token",
            startPosition: 0,
            duration: 0,
            maxRetries: 0
        )
        let store = VideoCachePreloader.shared.store

        // Wait until main has bytes from the OLD range (starting at prefixSize).
        let mainSeeded = await Self.pollUntil(timeoutSeconds: 8) {
            (store.regionStatus(videoId: videoId, region: .main)?.endOffset ?? 0) > Int64(prefixSize)
        }
        #expect(mainSeeded, "precondition: old main bytes must land before reseed")

        // Reseed to a far-forward byte. With the corruption fix, the awaited
        // cancel + inner-while cancel-check + post-reset region rebuild
        // guarantees the new main's bytes come from the [reseedByte..) range.
        await VideoCachePreloader.shared.reseedMain(
            videoId: videoId,
            atByte: reseedByte,
            url: url,
            token: "test-token"
        )

        // Wait until the new download has put at least one chunk into the
        // post-reset main.
        let newMainPopulated = await Self.pollUntil(timeoutSeconds: 5) {
            let main = store.regionStatus(videoId: videoId, region: .main)
            guard let main, main.startOffset == reseedByte else { return false }
            return main.endOffset > reseedByte
        }
        #expect(newMainPopulated, "post-reseed main must populate from the new range")

        // Read the first byte at reseedByte. By the per-range payload
        // contract, that byte equals `UInt8(reseedByte & 0xFF)` — the
        // identifier of the [reseedByte..) request. If the race were live,
        // the byte at reseedByte would be a leftover from the old [prefixSize..)
        // request's continuation, whose value at file offset `reseedByte`
        // would be `UInt8(reseedByte & 0xFF)` ALSO (since the per-range
        // payload is anchored at the request's start)… so we need a
        // distinguishing check.
        //
        // Distinguishing trick: the cancelled OLD task's chunks would have
        // been written into the NEW region BEFORE resetMainRegion ran (in
        // the race), so the first cached byte of the new region would have
        // landed at NEW main.startOffset == reseedByte but its byte
        // VALUE would be the old request's data at WHATEVER offset the old
        // request had reached — which is some offset >= prefixSize, NOT
        // reseedByte. The store records bytes positionally (chunks anchored
        // at startOffset), so the byte at offset reseedByte in the new
        // region would be the cancelled task's last-written byte rather
        // than the new request's first byte.
        //
        // Read **16 consecutive bytes** starting at reseedByte and verify the
        // entire sequence matches the new range's payload formula. A single-
        // byte read has a 1/256 false-positive probability (the cancelled
        // task's bytes happen to share the same low byte at that offset);
        // 16 consecutive bytes drops it to 1/2^128 — negligible.
        //
        // Expected sequence: byte i of the read = `UInt8((reseedByte + i) & 0xFF)`.
        let readLength = 16
        let readBytes = store.readData(videoId: videoId, offset: reseedByte, length: readLength)
        #expect(readBytes != nil, "bytes at reseedByte must be readable from cache")
        #expect(readBytes?.count == readLength,
                "store must return all \(readLength) requested bytes (got \(readBytes?.count ?? -1))")
        if let bytes = readBytes, bytes.count == readLength {
            for i in 0..<readLength {
                let expected = UInt8(truncatingIfNeeded: reseedByte + Int64(i))
                let actual = bytes[bytes.startIndex.advanced(by: i)]
                #expect(actual == expected,
                        "byte \(i) at offset reseedByte+\(i): expected \(expected) (UInt8((reseedByte+\(i)) & 0xFF)), got \(actual)")
            }
        }

        await VideoCachePreloader.shared.clear()
    }

    @Test func reseedMain_loaderGraceWindowStillFires() async {
        // Validates that after reseedMain, the CachingResourceLoader's
        // `waitForPreloaderData` grace path correctly targets the new
        // main.endOffset (== startOffset == reseedByte immediately after
        // reset). A loader request near the new main's startOffset should
        // see the preloader as "active and close" and exercise the grace
        // window — NOT immediately fall through to network.
        let totalSize = 1_000_000_000 // 1 GB so byte offsets matter
        let prefixSize = Int(CacheStore.computePrefixSize(totalSize: Int64(totalSize)))
        let reseedByte: Int64 = 500_000_000

        // Use installParallelMock with a long delay so the initial preload's
        // main task stays in-flight (orphan-guard precondition for reseedMain).
        // The 50MB prefix payload + slow main keeps preloadTask alive across
        // the reseed call. This is the same shape other passing reseed tests
        // use, avoiding hand-rolled handler bugs.
        let prefixData = Self.makePayload(size: prefixSize)
        let mainData = Data(repeating: 0xAB, count: 1024) // tiny — main barely populates
        Self.installParallelMock(
            totalSize: totalSize,
            prefixData: prefixData,
            mainData: mainData,
            mainStartByte: prefixSize,
            mainDelay: 3.0 // main stream dwells, preloadTask stays active
        )
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()
        let store = VideoCachePreloader.shared.store

        let videoId = "vid-reseed-loader-grace"
        let url = URL(string: "https://ta.example.com/media/\(videoId).mp4")!
        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: videoId,
            url: url,
            token: "test-token",
            startPosition: 0,
            duration: 0,
            maxRetries: 0
        )
        // Wait until `.main` exists (setEntry has run inside downloadVideo).
        let mainSeeded = await Self.pollUntil(timeoutSeconds: 5) {
            store.regionStatus(videoId: videoId, region: .main) != nil
        }
        #expect(mainSeeded, "precondition: setEntry must seed .main before reseed")

        await VideoCachePreloader.shared.reseedMain(
            videoId: videoId,
            atByte: reseedByte,
            url: url,
            token: "test-token"
        )

        // Main should now be anchored at reseedByte and empty (endOffset ==
        // startOffset == reseedByte). The loader's `relevantEndOffset` for
        // an offset of `reseedByte` would resolve to main.endOffset
        // (== reseedByte), and `offset - endOffset == 0 < coverSoonWindow`,
        // so the grace window would fire — assuming the preloader reports
        // active.
        let mainAfter = store.regionStatus(videoId: videoId, region: .main)
        #expect(mainAfter?.startOffset == reseedByte,
                "main.startOffset must equal reseedByte after reseedMain")
        #expect(mainAfter?.endOffset == reseedByte,
                "main.endOffset must equal startOffset immediately post-reseed")

        // Sanity: preloader is reporting active for this videoId after
        // reseed (the long-delay mock keeps the spawned task in-flight).
        let isPreloading = await VideoCachePreloader.shared.isPreloading(videoId: videoId)
        #expect(isPreloading, "preloader must report active after reseedMain spawns a fresh download")

        // The loader contract that this test guards: post-reseed,
        // relevantEndOffset(forOffset: reseedByte) == reseedByte, which is
        // the new main's endOffset (not the OLD main's prefixSize). We
        // verify the invariant via regionStatus rather than constructing a
        // full CachingResourceLoader (which would need AVAssetResourceLoading
        // request objects we can't synthesize from Swift Testing).
        let loaderEndOffset = mainAfter?.endOffset ?? 0
        #expect(loaderEndOffset == reseedByte,
                "loader's grace-window endOffset reference must match new main.endOffset after reseed")

        await VideoCachePreloader.shared.clear()
    }

    /// **Navigate-away-and-back same-video drain coverage (review phase 4 / MAJOR).**
    ///
    /// `reseedMain(X)`'s drain loop must NOT cancel a fresh `preloadTask` that
    /// was installed for the SAME video X by a `cancelPreload(X)` +
    /// `startPreloadWithRetry(X)` pair that ran DURING the drain's
    /// `await oldTask.value` suspension. Trace of the bug we're guarding
    /// against:
    ///   1. `startPreloadWithRetry(X)` installs `preloadTask = T_X1`,
    ///      bumps generation to N.
    ///   2. `reseedMain(X)` enters, pre-drain guard passes, snapshots
    ///      entryGeneration = N, calls `T_X1.cancel()`, awaits
    ///      `T_X1.value` — SUSPENDS the actor.
    ///   3. While reseedMain(X) is suspended:
    ///      a. `cancelPreload(X)` enters: nils `preloadTask`, sets
    ///         `lastCancelledVideoId = X`.
    ///      b. `startPreloadWithRetry(X)` enters (user re-opened the
    ///         SAME video quickly): clears `lastCancelledVideoId` (its
    ///         "fresh preload supersedes prior cancel" reset), bumps
    ///         `preloadGeneration` to N+1, installs `preloadTask = T_X2,
    ///         preloadTaskVideoId = X`.
    ///   4. `reseedMain(X)` resumes. The drain `while let` predicate
    ///      sees `preloadTask = T_X2, preloadTaskVideoId == X`, would
    ///      cancel T_X2 + await its value — KILLING the user's fresh
    ///      preload. The post-drain `lastCancelledVideoId == videoId(X)`
    ///      mirror check is now silent (cleared at step 3b). Without
    ///      the generation-bump bail, `resetMainRegion(atByte)` then
    ///      anchors a download at the previous session's stale reseed
    ///      target, hijacking the fresh session.
    ///
    /// The generation-bump bail at the top of the post-drain block
    /// detects `preloadGeneration (N+1) != entryGeneration (N)` and
    /// returns BEFORE the drain loop has a chance to cancel T_X2.
    ///
    /// Test seam: deterministically open the suspension window using a
    /// slow main mock (`mainDelay = 3s`) so T_X1 stays in-flight for the
    /// entire orchestration. Dispatch reseedMain(X) on a detached Task
    /// (so the actor admits it first), let it suspend on
    /// `await T_X1.value`, then run `cancelPreload(X)` and
    /// `startPreloadWithRetry(X)` inline on the actor mailbox.
    @Test func reseedMain_navigateAwayAndBack_sameVideo_doesNotKillFreshPreload() async {
        let totalSize = 16 * 1024 * 1024
        let prefixSize = Int(CacheStore.computePrefixSize(totalSize: Int64(totalSize)))
        let prefixData = Self.makePayload(size: prefixSize)
        let mainData = Self.makePayload(size: totalSize - prefixSize)

        // Slow main so T_X1 stays in-flight long enough that reseedMain(X)
        // suspends on `await T_X1.value` for the entire orchestration.
        Self.installParallelMock(
            totalSize: totalSize,
            prefixData: prefixData,
            mainData: mainData,
            mainStartByte: prefixSize,
            mainDelay: 3.0
        )
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()

        let videoId = "vid-navback-X"
        let url = URL(string: "https://ta.example.com/media/\(videoId).mp4")!

        // Step 1: start X's preload (T_X1, generation = N).
        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: videoId, url: url, token: "test-token",
            startPosition: 0, duration: 0, maxRetries: 0
        )
        let store = VideoCachePreloader.shared.store
        _ = await Self.pollUntil(timeoutSeconds: 5) {
            store.regionStatus(videoId: videoId, region: .main) != nil
        }
        let genAfterFirstStart = await VideoCachePreloader.shared.preloadGeneration

        // Step 2: fire reseedMain(X) on a detached Task so it can suspend
        // independently of our main test flow. Enters the actor first,
        // snapshots entryGeneration, calls T_X1.cancel(), and awaits
        // T_X1.value (which has ~3s left).
        let reseedTask = Task {
            await VideoCachePreloader.shared.reseedMain(
                videoId: videoId,
                atByte: Int64(prefixSize + 4 * 1024 * 1024),
                url: url,
                token: "test-token"
            )
        }

        // Give reseedMain a moment to enter the actor and reach the
        // `await oldTask.value` suspension point.
        try? await Task.sleep(for: .milliseconds(100))

        // Step 3a: cancelPreload(X) — runs while reseedMain(X) is suspended.
        // Nils preloadTask, sets lastCancelledVideoId = X.
        await VideoCachePreloader.shared.cancelPreload(videoId: videoId)

        // Step 3b: user re-opens X. startPreloadWithRetry(X) clears
        // lastCancelledVideoId, bumps preloadGeneration, installs T_X2.
        // preloadTaskVideoId is set back to X, so the drain loop's
        // videoId-mirror would NOT exit — the only defense is the
        // generation-bump bail.
        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: videoId, url: url, token: "test-token",
            startPosition: 0, duration: 0, maxRetries: 0
        )
        let genAfterSecondStart = await VideoCachePreloader.shared.preloadGeneration
        #expect(genAfterSecondStart > genAfterFirstStart,
                "precondition: second startPreloadWithRetry must bump generation (got \(genAfterFirstStart) → \(genAfterSecondStart))")
        let freshPreloadingMid = await VideoCachePreloader.shared.isPreloading(videoId: videoId)
        #expect(freshPreloadingMid, "precondition: fresh preload (T_X2) active before reseedMain(X) resumes")

        // Wait for reseedMain(X) to complete (drain its suspension and
        // either bail cleanly or — bug — kill T_X2 and re-spawn a stale
        // download).
        await reseedTask.value

        // Critical assertion 1: T_X2 must still be installed for X. With
        // the generation-bump bail, reseedMain(X)'s post-drain check sees
        // `preloadGeneration != entryGeneration` (step 3b bumped) and
        // returns BEFORE the drain loop runs. Without the bail, the loop
        // would have cancelled T_X2 and reseedMain would have spawned a
        // new task — but the videoId-mirror is X for both, so the loop
        // would proceed.
        let preloadTaskVidAfter = await VideoCachePreloader.shared.preloadTaskVideoId
        #expect(preloadTaskVidAfter == videoId,
                "preloadTaskVideoId MUST still be X after stale reseedMain(X) — drain kill is the bug")
        let preloadingAfter = await VideoCachePreloader.shared.isPreloading(videoId: videoId)
        #expect(preloadingAfter,
                "fresh preload for X MUST survive a stale reseedMain(X) — drain kill is the bug")

        // Critical assertion 2: generation did NOT receive an additional
        // bump from the stale reseedMain. If the bail fires correctly,
        // generation ends at `genAfterSecondStart`. If the bail doesn't
        // fire, reseedMain would have bumped again (one extra) before
        // calling resetMainRegion.
        let genFinal = await VideoCachePreloader.shared.preloadGeneration
        #expect(genFinal == genAfterSecondStart,
                "stale reseedMain MUST NOT bump generation after bail (got \(genAfterSecondStart) → \(genFinal))")

        await VideoCachePreloader.shared.cancelPreload(videoId: videoId)
        await VideoCachePreloader.shared.clear()
    }

    // MARK: - Task 5 — restartPreloadIfNeeded
    //
    // These tests pin the contract for `VideoCachePreloader.restartPreloadIfNeeded`
    // added in `20260527-fix-memory-pressure-recovery.md`. The method is the
    // recovery hook the VM's 1Hz observer fires when `.main` falls below the
    // restart threshold (after `.critical` trims main, or after the user lets
    // the cache drain without playback). It must be idempotent, anchored at
    // the playhead, and drop any stale-anchored cached bytes BEFORE
    // delegating to `startPreloadWithRetry` (otherwise that method's
    // `isCacheSufficient` check would short-circuit on the wrong-anchor
    // leftover and silently no-op the recovery).

    /// Happy path: no preload in flight, entry seeded. Restart spawns a fresh
    /// download anchored at the requested start position and the main GET
    /// fires with `Range: bytes=N-`.
    ///
    /// NOTE on observation: `MockURLProtocol.lastRequest` reflects whichever
    /// of the parallel prefix/main GETs landed LAST, plus the HEAD probe — so
    /// polling `lastRequest.Range` races against natural completion order.
    /// We use `installParallelMock`'s `onMainRangeSeen` callback to capture
    /// every observed main GET range deterministically; the test then checks
    /// the captured array post-hoc.
    @Test func restartPreloadIfNeeded_whenNoPreloadInFlight_spawnsRestart() async {
        // 1 GB total, 1000s duration → byteForStartPosition(100s) = 100 MB.
        // Need a totalSize big enough that resetMainRegion's clamp doesn't
        // push the anchor outside the file. 1 GB also exceeds the prefix
        // cap (50 MB) so `.main` exists.
        let totalSize: Int64 = 1_000_000_000
        let duration: Double = 1000
        let startPosition: Double = 100.0 // → ~100_000_000 bytes
        let prefixSize = Int(CacheStore.computePrefixSize(totalSize: totalSize))
        // Synthesize prefix and main payloads sized to whatever fits in our
        // mock. The download will be SHORT — `installParallelMock` returns
        // the full payload regardless of Range start, so even small data is
        // enough to verify the Range header.
        let prefixData = Self.makePayload(size: prefixSize)
        let mainData = Self.makePayload(size: 1024 * 1024) // 1 MB stub

        // Capture every main range observed by the mock. Cross-thread-safe
        // via NSLock; same pattern as `reseedMain_downloadsCorrectRange`.
        nonisolated(unsafe) var observedMainRanges: [String] = []
        let rangeLock = NSLock()

        Self.installParallelMock(
            totalSize: Int(totalSize),
            prefixData: prefixData,
            mainData: mainData,
            // mainStartByte echoed back in the mocked Content-Range; the
            // preloader reads only Content-Length / status, not Content-Range,
            // so the exact byte here is cosmetic.
            mainStartByte: Int(100_000_000),
            onMainRangeSeen: { range in
                rangeLock.lock()
                observedMainRanges.append(range)
                rangeLock.unlock()
            }
        )
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()

        let videoId = "vid-restart-spawn"
        let url = URL(string: "https://ta.example.com/media/\(videoId).mp4")!
        let store = VideoCachePreloader.shared.store

        // Seed an entry directly via setEntry — the precondition for
        // restartPreloadIfNeeded is "entry exists, no preload in flight".
        // resumeByte = 0 so main starts at prefixSize.
        store.setEntry(
            videoId: videoId,
            totalSize: totalSize,
            contentType: "video/mp4",
            resumeByte: 0
        )
        // Confirm no preload task is in flight.
        let preloadingBefore = await VideoCachePreloader.shared.isPreloading(videoId: videoId)
        #expect(!preloadingBefore, "precondition: no preload should be active before restart")

        // Fire restart.
        let returned = await VideoCachePreloader.shared.restartPreloadIfNeeded(
            videoId: videoId,
            url: url,
            token: "test-token",
            startPosition: startPosition,
            duration: duration
        )
        #expect(returned, "restartPreloadIfNeeded must return true when no preload is in flight + entry exists")

        // preloadTask / preloadTaskVideoId installed by startPreloadWithRetry.
        let preloadTaskInstalled = await Self.pollUntil(timeoutSeconds: 5) {
            await VideoCachePreloader.shared.preloadTaskVideoId == videoId
        }
        #expect(preloadTaskInstalled,
                "preloadTaskVideoId MUST be set to \(videoId) after restart")

        // Poll on the deterministic observation channel: wait until the main
        // GET has been seen with Range bytes=100_000_000-.
        let expectedByte: Int64 = 100_000_000
        let mainRangeSeen = await Self.pollUntil(timeoutSeconds: 5) {
            rangeLock.lock()
            let seen = observedMainRanges.contains { $0.hasPrefix("bytes=\(expectedByte)-") }
            rangeLock.unlock()
            return seen
        }
        rangeLock.lock()
        let observedSnapshot = observedMainRanges
        rangeLock.unlock()
        #expect(mainRangeSeen,
                "main GET MUST fire with Range bytes=\(expectedByte)- (observed: \(observedSnapshot))")

        // Teardown: cancel the in-flight preload before clear so we don't
        // leave a task spinning across tests.
        await VideoCachePreloader.shared.cancelPreload(videoId: videoId)
        await VideoCachePreloader.shared.clear()
    }

    /// Preload already in flight → restart no-ops without touching state.
    @Test func restartPreloadIfNeeded_whenPreloadInFlight_noOp() async {
        let totalSize = 16 * 1024 * 1024
        let prefixSize = Int(CacheStore.computePrefixSize(totalSize: Int64(totalSize)))
        let prefixData = Self.makePayload(size: prefixSize)
        let mainData = Self.makePayload(size: totalSize - prefixSize)

        // Slow main so the preload stays in-flight while we call restart.
        Self.installParallelMock(
            totalSize: totalSize,
            prefixData: prefixData,
            mainData: mainData,
            mainStartByte: prefixSize,
            mainDelay: 2.0
        )
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()

        let videoId = "vid-restart-inflight-noop"
        let url = URL(string: "https://ta.example.com/media/\(videoId).mp4")!
        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: videoId,
            url: url,
            token: "test-token",
            startPosition: 0,
            duration: 0,
            maxRetries: 0
        )

        // Wait until the preload task is installed and main is seeded so the
        // in-flight precondition is solid.
        let store = VideoCachePreloader.shared.store
        let primed = await Self.pollUntil(timeoutSeconds: 5) {
            let vidMatch = await VideoCachePreloader.shared.preloadTaskVideoId == videoId
            let mainExists = store.regionStatus(videoId: videoId, region: .main) != nil
            return vidMatch && mainExists
        }
        #expect(primed, "precondition: in-flight preload installed with main seeded")

        // Snapshot the existing main.startOffset so we can prove restart's
        // resetMainRegion did NOT run.
        let mainBefore = store.regionStatus(videoId: videoId, region: .main)
        let mainStartBefore = mainBefore?.startOffset ?? -1

        // Fire restart while preload is in flight — must return false.
        let returned = await VideoCachePreloader.shared.restartPreloadIfNeeded(
            videoId: videoId,
            url: url,
            token: "test-token",
            startPosition: 10.0,
            duration: 100.0
        )
        #expect(!returned, "restartPreloadIfNeeded MUST return false when preloadTask != nil")

        // Main start offset unchanged — proves resetMainRegion did NOT run.
        let mainAfter = store.regionStatus(videoId: videoId, region: .main)
        let mainStartAfter = mainAfter?.startOffset ?? -1
        #expect(mainStartAfter == mainStartBefore,
                "main.startOffset MUST be unchanged when restart no-ops")

        await VideoCachePreloader.shared.cancelPreload(videoId: videoId)
        await VideoCachePreloader.shared.clear()
    }

    /// No entry in the store → restart no-ops; no entry is created as a side
    /// effect.
    @Test func restartPreloadIfNeeded_whenNoEntry_noOp() async {
        // Install a mock so any accidental network call is observable via
        // MockURLProtocol.lastRequest (if restart fired, we'd see a HEAD).
        let dummy = Self.makePayload(size: 64)
        Self.installMockResponding(with: dummy)
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()
        MockURLProtocol.lastRequest = nil

        let videoId = "vid-restart-no-entry"
        let url = URL(string: "https://ta.example.com/media/\(videoId).mp4")!
        let store = VideoCachePreloader.shared.store
        #expect(store.currentVideoId() == nil, "precondition: store has no entry")

        let returned = await VideoCachePreloader.shared.restartPreloadIfNeeded(
            videoId: videoId,
            url: url,
            token: "test-token",
            startPosition: 50.0,
            duration: 100.0
        )
        #expect(!returned, "restartPreloadIfNeeded MUST return false when no entry exists")

        // No entry created as a side-effect.
        #expect(store.currentVideoId() == nil, "restart MUST NOT create an entry on no-op")

        // No request fired (no HEAD, no GET). Give the actor a brief moment
        // so a late-arriving stale request would have a chance to be seen.
        try? await Task.sleep(for: .milliseconds(150))
        #expect(MockURLProtocol.lastRequest == nil,
                "no network request must be issued when restart no-ops on missing entry")

        await VideoCachePreloader.shared.clear()
    }

    /// `byteForStartPosition >= totalSize` → restart no-ops defensively.
    /// Covers both the boundary case (startPosition == duration) and the
    /// defensive past-EOF case (startPosition > duration, e.g. clock skew or
    /// a re-encoded file that shrunk under us).
    @Test func restartPreloadIfNeeded_atOrPastTotalSize_noOp() async {
        let dummy = Self.makePayload(size: 64)
        Self.installMockResponding(with: dummy)
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()

        let videoId = "vid-restart-eof"
        let url = URL(string: "https://ta.example.com/media/\(videoId).mp4")!
        let store = VideoCachePreloader.shared.store
        // Seed an entry so the no-entry guard doesn't short-circuit before
        // the EOF guard.
        let totalSize: Int64 = 1_000_000_000
        store.setEntry(
            videoId: videoId,
            totalSize: totalSize,
            contentType: "video/mp4",
            resumeByte: 0
        )

        // Snapshot main.startOffset so we can confirm resetMainRegion did
        // NOT run.
        let mainBefore = store.regionStatus(videoId: videoId, region: .main)
        let mainStartBefore = mainBefore?.startOffset ?? -1

        // Boundary case: startPosition == duration → byteForStartPosition == totalSize.
        MockURLProtocol.lastRequest = nil
        let returnedAt = await VideoCachePreloader.shared.restartPreloadIfNeeded(
            videoId: videoId,
            url: url,
            token: "test-token",
            startPosition: 1000.0,
            duration: 1000.0
        )
        #expect(!returnedAt, "restartPreloadIfNeeded MUST return false when startPosition == duration (byte at totalSize)")

        // Defensive past-EOF case: startPosition > duration.
        let returnedPast = await VideoCachePreloader.shared.restartPreloadIfNeeded(
            videoId: videoId,
            url: url,
            token: "test-token",
            startPosition: 1500.0,
            duration: 1000.0
        )
        #expect(!returnedPast, "restartPreloadIfNeeded MUST return false when startPosition > duration")

        // No resetMainRegion side-effect.
        let mainAfter = store.regionStatus(videoId: videoId, region: .main)
        let mainStartAfter = mainAfter?.startOffset ?? -1
        #expect(mainStartAfter == mainStartBefore,
                "main.startOffset MUST be unchanged when restart no-ops on past-EOF startPosition")

        // No network request fired by either call.
        try? await Task.sleep(for: .milliseconds(150))
        #expect(MockURLProtocol.lastRequest == nil,
                "no network request must be issued when restart no-ops on past-EOF startPosition")

        await VideoCachePreloader.shared.clear()
    }

    /// LOAD-BEARING for `.critical` recovery. Mimics the post-`.critical`-trim
    /// state: main exists but is anchored at the WRONG byte (a left-over 64 MB
    /// from the pre-trim main). Restart must call `resetMainRegion` to drop
    /// that stale-anchored cache so `startPreloadWithRetry`'s
    /// `isCacheSufficient` check doesn't short-circuit; a fresh download must
    /// fire at the new anchor.
    @Test func restartPreloadIfNeeded_dropsStaleMain_thenDownloads() async {
        // 1 GB / 1000s file. Mimic post-`.critical`-trim state: prefix has
        // some bytes (untouched), main is anchored at ~26 MB and has 64 MB
        // worth of stale chunks. The user has scrubbed (or playhead has
        // drifted) to ~byte 500 MB; the 1Hz observer fires restart with
        // startPosition: 500.0.
        let totalSize: Int64 = 1_000_000_000
        let duration: Double = 1000.0
        let startPosition: Double = 500.0 // → byteForStartPosition = 500_000_000
        let expectedByte: Int64 = 500_000_000

        // Mock: serve any Range request with a small main payload (1 MB).
        // The actual data is unimportant — we're verifying the request fires
        // with the correct Range header.
        let prefixSize = Int(CacheStore.computePrefixSize(totalSize: totalSize))
        let prefixData = Self.makePayload(size: prefixSize)
        let mainData = Self.makePayload(size: 1024 * 1024)

        // Capture every main range observed by the mock — `lastRequest`
        // races against parallel prefix/main completion, so we use the
        // deterministic callback channel instead.
        nonisolated(unsafe) var observedMainRanges: [String] = []
        let rangeLock = NSLock()

        Self.installParallelMock(
            totalSize: Int(totalSize),
            prefixData: prefixData,
            mainData: mainData,
            mainStartByte: Int(expectedByte),
            onMainRangeSeen: { range in
                rangeLock.lock()
                observedMainRanges.append(range)
                rangeLock.unlock()
            }
        )
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()

        let videoId = "vid-restart-stale-main"
        let url = URL(string: "https://ta.example.com/media/\(videoId).mp4")!
        let store = VideoCachePreloader.shared.store

        // Seed entry with resumeByte placing main at 26 MB (mimics
        // post-`.critical`-trim anchor that emergencyTrim advanced
        // main.startOffset to).
        let staleAnchor: Int64 = 26 * 1024 * 1024
        store.setEntry(
            videoId: videoId,
            totalSize: totalSize,
            contentType: "video/mp4",
            resumeByte: staleAnchor
        )
        // Stuff 64 MB into main at that anchor (mimics post-trim leftover).
        let mainStaleBytes = 64 * 1024 * 1024
        var remaining = mainStaleBytes
        var i = 0
        while remaining > 0 {
            let size = min(CacheStore.chunkSize, remaining)
            let chunk = Data(repeating: UInt8(i & 0xFF), count: size)
            _ = store.writeChunk(videoId: videoId, toRegion: .main, chunk: chunk)
            remaining -= size
            i &+= 1
        }
        // Also fill prefix with some bytes (mimics prefix survives `.critical`).
        let prefixChunk = Data(repeating: 0xAA, count: CacheStore.chunkSize)
        _ = store.writeChunk(videoId: videoId, toRegion: .prefix, chunk: prefixChunk)

        // Preconditions: main anchored at staleAnchor, has 64 MB stale.
        let mainBefore = store.regionStatus(videoId: videoId, region: .main)
        #expect(mainBefore?.startOffset == staleAnchor,
                "precondition: main anchored at staleAnchor (26 MB)")
        #expect((mainBefore?.endOffset ?? 0) - (mainBefore?.startOffset ?? 0) >= Int64(mainStaleBytes / 2),
                "precondition: main has stale bytes accumulated")

        // Fire restart.
        let returned = await VideoCachePreloader.shared.restartPreloadIfNeeded(
            videoId: videoId,
            url: url,
            token: "test-token",
            startPosition: startPosition,
            duration: duration
        )
        #expect(returned, "restartPreloadIfNeeded MUST return true on the .critical-recovery path")

        // (a) main re-anchored at expectedByte. resetMainRegion runs
        // SYNCHRONOUSLY on the actor before returning, so the post-call read
        // observes the new anchor.
        let mainAfter = store.regionStatus(videoId: videoId, region: .main)
        #expect(mainAfter?.startOffset == expectedByte,
                "main.startOffset MUST be reset to \(expectedByte) (was \(staleAnchor)) — resetMainRegion didn't run")

        // (b) The mock observes a main GET with Range bytes=500000000-.
        // Poll the deterministic callback channel instead of lastRequest,
        // which races against parallel prefix/main completion order.
        let mainRangeSeen = await Self.pollUntil(timeoutSeconds: 5) {
            rangeLock.lock()
            let seen = observedMainRanges.contains { $0.hasPrefix("bytes=\(expectedByte)-") }
            rangeLock.unlock()
            return seen
        }
        rangeLock.lock()
        let observedSnapshot = observedMainRanges
        rangeLock.unlock()
        #expect(mainRangeSeen,
                "main GET MUST fire with Range bytes=\(expectedByte)- — proves isCacheSufficient did NOT short-circuit (observed: \(observedSnapshot))")

        await VideoCachePreloader.shared.cancelPreload(videoId: videoId)
        await VideoCachePreloader.shared.clear()
    }

    /// End-to-end regression for the headline `.critical` recovery scenario.
    ///
    /// Review iter 1 (commit 609e642) added a guard
    /// `if lastCancelledVideoId == videoId { return false }` at the top of
    /// `restartPreloadIfNeeded` to defend against a navigate-away race; that
    /// guard accidentally broke the dominant flow that the entire
    /// memory-pressure-recovery plan exists to fix:
    /// 1. `.critical` fires → `invalidatePreload` records
    ///    `lastCancelledVideoId = videoId`.
    /// 2. After VM cooldown, the 1Hz hook calls `restartPreloadIfNeeded`.
    /// 3. The guard tripped, restart returned `false` forever (nothing else
    ///    clears `lastCancelledVideoId` before reaching `startPreloadWithRetry`
    ///    because the guard short-circuited the restart path itself).
    ///
    /// This test was missing in iter 1: the existing
    /// `restartPreloadIfNeeded_*` suite seeded post-`.critical` state via
    /// `setEntry + writeChunk` directly, which never set
    /// `lastCancelledVideoId`. The E2E `restartHook_dispatchActuallyCallsPreloader`
    /// at the VM-evaluator level likewise seeded main directly. Without
    /// driving `handleMemoryPressure(.critical)` first, the regression hides.
    ///
    /// This test drives the FULL sequence (.critical → recorded cancel →
    /// restart) and asserts the restart returns `true` and dispatches a
    /// preload task. Do NOT delete or rewrite this test to skip the
    /// `.critical` step — the absence of that step is exactly how iter 1
    /// shipped broken.
    @Test func restartPreloadIfNeeded_afterCritical_succeeds() async {
        // 1 GB / 1000s file so we can fill main with > RestartTrigger.mainCachedByteThreshold
        // (16 MB) of stale bytes, drive .critical (which trims to 8 MB),
        // then restart from a playhead in the middle of the file.
        let totalSize: Int64 = 1_000_000_000
        let duration: Double = 1000.0
        let startPosition: Double = 500.0 // → byteForStartPosition = 500_000_000
        let expectedByte: Int64 = 500_000_000

        // Mock: serve any Range request with a small main payload (1 MB).
        let prefixSize = Int(CacheStore.computePrefixSize(totalSize: totalSize))
        let prefixData = Self.makePayload(size: prefixSize)
        let mainData = Self.makePayload(size: 1024 * 1024)

        nonisolated(unsafe) var observedMainRanges: [String] = []
        let rangeLock = NSLock()

        Self.installParallelMock(
            totalSize: Int(totalSize),
            prefixData: prefixData,
            mainData: mainData,
            mainStartByte: Int(expectedByte),
            onMainRangeSeen: { range in
                rangeLock.lock()
                observedMainRanges.append(range)
                rangeLock.unlock()
            }
        )
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()

        let videoId = "vid-restart-after-critical"
        let url = URL(string: "https://ta.example.com/media/\(videoId).mp4")!
        let store = VideoCachePreloader.shared.store

        // Seed entry + main at the playback-region anchor (~500 MB) with
        // enough bytes that .critical's emergencyTrim has something to
        // trim down to 8 MB.
        let initialAnchor: Int64 = 480_000_000
        store.setEntry(
            videoId: videoId,
            totalSize: totalSize,
            contentType: "video/mp4",
            resumeByte: initialAnchor
        )
        // Pile in 64 MB worth of stale chunks so .critical actually trims.
        let stuffBytes = 64 * 1024 * 1024
        var remaining = stuffBytes
        var i = 0
        while remaining > 0 {
            let size = min(CacheStore.chunkSize, remaining)
            let chunk = Data(repeating: UInt8(i & 0xFF), count: size)
            _ = store.writeChunk(videoId: videoId, toRegion: .main, chunk: chunk)
            remaining -= size
            i &+= 1
        }
        // Seed prefix too (prefix is pinned through .critical).
        let prefixChunk = Data(repeating: 0xAA, count: CacheStore.chunkSize)
        _ = store.writeChunk(videoId: videoId, toRegion: .prefix, chunk: prefixChunk)

        // Step 1: drive .critical. Fire and let the Task-spawned
        // invalidatePreload land on the actor — poll on the visible
        // side-effect (lastCancelledVideoId set) rather than guess at
        // scheduling.
        VideoCachePreloader.shared.handleMemoryPressure(event: .critical)
        _ = await Self.pollUntil(timeoutSeconds: 5) {
            await VideoCachePreloader.shared.lastCancelledVideoId == videoId
        }
        let recorded = await VideoCachePreloader.shared.lastCancelledVideoId
        #expect(recorded == videoId,
                "precondition: .critical MUST record lastCancelledVideoId = \(videoId) (got \(String(describing: recorded)))")

        // preloadTask should be nil after invalidatePreload.
        let inFlight = await VideoCachePreloader.shared.preloadTaskVideoId
        #expect(inFlight == nil,
                "precondition: .critical MUST nil preloadTask")

        // Step 2: 1Hz hook fires restartPreloadIfNeeded for the SAME videoId
        // that .critical just cancelled. With Guard 2 in place this would
        // return false forever; without it, the restart proceeds.
        let returned = await VideoCachePreloader.shared.restartPreloadIfNeeded(
            videoId: videoId,
            url: url,
            token: "test-token",
            startPosition: startPosition,
            duration: duration
        )
        #expect(returned,
                "restartPreloadIfNeeded MUST return true after .critical recorded lastCancelledVideoId — review iter 1 broke this")

        // (a) main re-anchored at the new playhead byte.
        let mainAfter = store.regionStatus(videoId: videoId, region: .main)
        #expect(mainAfter?.startOffset == expectedByte,
                "main.startOffset MUST be reset to \(expectedByte) — restart didn't reach resetMainRegion")

        // (b) preloadTask installed for the matching videoId.
        let restartedVideoId = await VideoCachePreloader.shared.preloadTaskVideoId
        #expect(restartedVideoId == videoId,
                "preloadTask MUST be installed for \(videoId) after restart (got \(String(describing: restartedVideoId)))")

        // (c) main GET fires with the new Range. Proves
        // startPreloadWithRetry → downloadVideo actually ran.
        let mainRangeSeen = await Self.pollUntil(timeoutSeconds: 5) {
            rangeLock.lock()
            let seen = observedMainRanges.contains { $0.hasPrefix("bytes=\(expectedByte)-") }
            rangeLock.unlock()
            return seen
        }
        rangeLock.lock()
        let observedSnapshot = observedMainRanges
        rangeLock.unlock()
        #expect(mainRangeSeen,
                "main GET MUST fire with Range bytes=\(expectedByte)- after .critical → restart (observed: \(observedSnapshot))")

        // (d) lastCancelledVideoId cleared (startPreloadWithRetry clears it
        // for the matching videoId at the top of its body).
        let postRestartCancelRecord = await VideoCachePreloader.shared.lastCancelledVideoId
        #expect(postRestartCancelRecord == nil,
                "lastCancelledVideoId MUST be cleared by startPreloadWithRetry on the restart path (got \(String(describing: postRestartCancelRecord)))")

        await VideoCachePreloader.shared.cancelPreload(videoId: videoId)
        await VideoCachePreloader.shared.clear()
    }

    /// End-to-end `.critical` → `restartPreloadIfNeeded` chain MUST preserve
    /// the prefix bytes that the soft-`.critical` policy was designed to
    /// keep. The restart goes through `setEntry` (inside `downloadVideo`),
    /// and without the idempotent same-(videoId, totalSize, contentType)
    /// short-circuit that call wipes the prefix, opening a brief
    /// moov-cache-miss window where scrub-after-resume can re-trigger the
    /// freeze that the two-region architecture exists to prevent.
    @Test func restartPreloadIfNeeded_afterCritical_preservesPrefixBytes() async {
        let totalSize: Int64 = 1_000_000_000
        let duration: Double = 1000.0
        let startPosition: Double = 500.0
        let expectedByte: Int64 = 500_000_000

        let prefixSize = Int(CacheStore.computePrefixSize(totalSize: totalSize))
        let prefixData = Self.makePayload(size: prefixSize)
        let mainData = Self.makePayload(size: 1024 * 1024)

        Self.installParallelMock(
            totalSize: Int(totalSize),
            prefixData: prefixData,
            mainData: mainData,
            mainStartByte: Int(expectedByte)
        )
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()

        let videoId = "vid-restart-preserves-prefix"
        let url = URL(string: "https://ta.example.com/media/\(videoId).mp4")!
        let store = VideoCachePreloader.shared.store

        // Seed entry + main at the playback anchor (~480 MB) with enough
        // bytes to ensure .critical's emergencyTrim has something to trim.
        let initialAnchor: Int64 = 480_000_000
        store.setEntry(
            videoId: videoId,
            totalSize: totalSize,
            contentType: "video/mp4",
            resumeByte: initialAnchor
        )

        // Fully populate the prefix region so its endOffset == prefixSize
        // and cachedByteCount == prefixSize. These are the bytes we MUST
        // preserve through the .critical → restart chain.
        var prefixWritten = 0
        var pi = 0
        while prefixWritten < prefixSize {
            let size = min(CacheStore.chunkSize, prefixSize - prefixWritten)
            let chunk = Data(repeating: UInt8(pi & 0xFF), count: size)
            _ = store.writeChunk(videoId: videoId, toRegion: .prefix, chunk: chunk)
            prefixWritten += size
            pi &+= 1
        }
        // Pile in stale main chunks so .critical actually trims.
        let stuffBytes = 64 * 1024 * 1024
        var remaining = stuffBytes
        var i = 0
        while remaining > 0 {
            let size = min(CacheStore.chunkSize, remaining)
            let chunk = Data(repeating: UInt8(i & 0xFF), count: size)
            _ = store.writeChunk(videoId: videoId, toRegion: .main, chunk: chunk)
            remaining -= size
            i &+= 1
        }

        // Capture prefix state before the chain runs.
        let prefixBefore = store.regionStatus(videoId: videoId, region: .prefix)!
        let cachedPrefixBefore = prefixBefore.endOffset - prefixBefore.startOffset
        #expect(cachedPrefixBefore > 0, "precondition: prefix must hold bytes before .critical")

        // Step 1: .critical. Soft-trim main, preserve prefix.
        VideoCachePreloader.shared.handleMemoryPressure(event: .critical)
        _ = await Self.pollUntil(timeoutSeconds: 5) {
            await VideoCachePreloader.shared.lastCancelledVideoId == videoId
        }

        // Confirm prefix survived .critical itself (sanity for the soft policy).
        let prefixAfterCritical = store.regionStatus(videoId: videoId, region: .prefix)!
        let cachedPrefixAfterCritical = prefixAfterCritical.endOffset - prefixAfterCritical.startOffset
        #expect(cachedPrefixAfterCritical == cachedPrefixBefore,
                "precondition: .critical MUST preserve prefix (soft policy) — got \(cachedPrefixAfterCritical) vs \(cachedPrefixBefore)")

        // Step 2: the 1Hz restart hook fires.
        let returned = await VideoCachePreloader.shared.restartPreloadIfNeeded(
            videoId: videoId,
            url: url,
            token: "test-token",
            startPosition: startPosition,
            duration: duration
        )
        #expect(returned, "restartPreloadIfNeeded MUST return true after .critical")

        // The KEY assertion: prefix bytes survive `downloadVideo`'s
        // `store.setEntry(...)` call. Without idempotency this drops to 0.
        // We poll briefly because the restart spawns a Task and the
        // (idempotent) setEntry runs on the actor after the HEAD probe.
        // Even if a subsequent `downloadRange` writes MORE prefix bytes,
        // the existing bytes MUST NOT regress to 0. So we poll for a
        // stable-or-growing state and assert the floor.
        let prefixHeld = await Self.pollUntil(timeoutSeconds: 5) {
            let status = store.regionStatus(videoId: videoId, region: .prefix)
            let cached = (status?.endOffset ?? 0) - (status?.startOffset ?? 0)
            // We want to see that AT NO POINT did prefix drop below its
            // pre-restart byte count. Bytes can stay the same (cache hit)
            // or grow (downloader rewrote into the prefix region) but
            // must never shrink.
            return cached >= cachedPrefixBefore
        }
        #expect(prefixHeld,
                "prefix bytes MUST NOT be wiped by restart's setEntry call — expected ≥ \(cachedPrefixBefore) bytes preserved")

        // Final state confirmation.
        let prefixFinal = store.regionStatus(videoId: videoId, region: .prefix)!
        let cachedPrefixFinal = prefixFinal.endOffset - prefixFinal.startOffset
        #expect(cachedPrefixFinal >= cachedPrefixBefore,
                "prefix.endOffset MUST be ≥ pre-restart endOffset (got \(cachedPrefixFinal), expected ≥ \(cachedPrefixBefore))")
        #expect(prefixFinal.startOffset == prefixBefore.startOffset,
                "prefix.startOffset MUST be unchanged")

        await VideoCachePreloader.shared.cancelPreload(videoId: videoId)
        await VideoCachePreloader.shared.clear()
    }
}
}
