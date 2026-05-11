import Testing
import Foundation
@testable import TAClient

extension DataLayerSuite {
@Suite(.serialized) struct CachingResourceLoaderTests {

    init() {
        MockResponse.tearDown()
    }

    // MARK: - URL conversion (regression)

    @Test func cachingURL_roundTrip_preservesOriginalScheme() {
        let original = URL(string: "https://ta.example.com/media/video.mp4?sig=abc")!
        let caching = CachingResourceLoader.cachingURL(from: original)
        #expect(caching != nil)
        #expect(caching?.scheme == "itacache")
        let restored = CachingResourceLoader.originalURL(from: caching!)
        #expect(restored?.absoluteString == original.absoluteString)
    }

    // MARK: - Task tracking

    @Test func registerTask_addsToActiveTasks_underLock() {
        let loader = CachingResourceLoader(
            videoId: "vid1",
            originalURL: URL(string: "https://ta.example.com/media/video.mp4")!,
            token: "test-token"
        )
        #expect(loader.activeTaskCount() == 0)

        // Create a task that never completes on its own (so we can observe it in-flight)
        let neverFinishing = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        // Since ObjectIdentifier requires AnyObject, use any class instance as a stand-in key.
        let keyObject = NSObject()
        let key = ObjectIdentifier(keyObject)

        loader.registerTask(neverFinishing, forKey: key)
        #expect(loader.activeTaskCount() == 1)

        // cleanup
        loader.cancelTask(forKey: key)
        #expect(loader.activeTaskCount() == 0)
    }

    @Test func cancelTask_cancelsAndRemovesTrackedTask() async {
        let loader = CachingResourceLoader(
            videoId: "vid1",
            originalURL: URL(string: "https://ta.example.com/media/video.mp4")!,
            token: "test-token"
        )

        // Flag we can observe to confirm the task was cancelled.
        let wasCancelledBox = CancelFlag()

        let task = Task<Void, Never> {
            // Wait up to 5 seconds but break early on cancellation.
            for _ in 0..<100 {
                if Task.isCancelled {
                    wasCancelledBox.value = true
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        let keyObject = NSObject()
        let key = ObjectIdentifier(keyObject)
        loader.registerTask(task, forKey: key)
        #expect(loader.activeTaskCount() == 1)

        loader.cancelTask(forKey: key)

        // Wait for task to observe cancellation.
        _ = await task.value
        #expect(wasCancelledBox.value == true)
        #expect(loader.activeTaskCount() == 0)
    }

    @Test func removeActiveTask_withoutCancellation_leavesTaskRunning() async {
        let loader = CachingResourceLoader(
            videoId: "vid1",
            originalURL: URL(string: "https://ta.example.com/media/video.mp4")!,
            token: "test-token"
        )

        let didComplete = CancelFlag()

        let task = Task<Void, Never> {
            try? await Task.sleep(for: .milliseconds(100))
            didComplete.value = true
        }

        let keyObject = NSObject()
        let key = ObjectIdentifier(keyObject)
        loader.registerTask(task, forKey: key)
        loader.removeActiveTask(forKey: key)
        #expect(loader.activeTaskCount() == 0)

        _ = await task.value
        #expect(didComplete.value == true, "removeActiveTask must not cancel the task")
    }

    @Test func cancelTask_unknownKey_isNoOp() {
        let loader = CachingResourceLoader(
            videoId: "vid1",
            originalURL: URL(string: "https://ta.example.com/media/video.mp4")!,
            token: "test-token"
        )
        let keyObject = NSObject()
        let key = ObjectIdentifier(keyObject)
        // No crash, no change to count.
        loader.cancelTask(forKey: key)
        #expect(loader.activeTaskCount() == 0)
    }

    // MARK: - Sync store access (Task 10 / C1b)

    /// Regression: after Task 10, `CachingResourceLoader` captures a
    /// `CacheStore` reference and must read cache hits synchronously — no
    /// `await` on the hot path. `AVAssetResourceLoadingRequest` has no public
    /// initializer, so we verify the contract one layer down: the loader's
    /// injected store returns cached data in a single synchronous call. The
    /// object-identity check (`loader.store === store`) is the load-bearing
    /// assertion — it's impossible to satisfy without direct reference
    /// capture. The timing bound is a loose sanity threshold (50ms, broad
    /// enough for constrained CI runners) purely to catch an accidental
    /// executor hop that would add hundreds of ms on a contended VM.
    @Test func cacheHit_readsSynchronously_fromInjectedStore() {
        let store = CacheStore()
        let videoId = "vid-sync-hit"
        let payload = Data(repeating: 0xEE, count: 64 * 1024) // 64 KB
        // Small payload (64 KB) is well below the prefix lower bound (8 MB),
        // so `setEntry` creates only a `.prefix` region — write goes there.
        store.setEntry(
            videoId: videoId,
            totalSize: Int64(payload.count),
            contentType: "video/mp4",
            resumeByte: 0
        )
        _ = store.writeChunk(videoId: videoId, toRegion: .prefix, chunk: payload)

        let loader = CachingResourceLoader(
            videoId: videoId,
            originalURL: URL(string: "https://ta.example.com/media/video.mp4")!,
            token: "test-token",
            store: store
        )

        // The loader must hold the SAME store reference (object identity) so
        // that `fillDataRequest` reads observe writes performed by the
        // preloader actor. This is the primary contract assertion.
        #expect(loader.store === store)

        // Direct sync read via the loader's captured store reference. Loose
        // timing bound to catch gross regressions (executor hop, network
        // fallback) without being flaky on CI runners.
        let start = CFAbsoluteTimeGetCurrent()
        let data = loader.store.readData(videoId: videoId, offset: 0, length: 4096)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        #expect(data != nil)
        #expect(data?.count == 4096)
        #expect(elapsed < 0.05, "Sync cache read took \(elapsed * 1000) ms — expected <50 ms")
    }

    /// Companion: a cache miss on the loader's injected store returns `nil`
    /// synchronously (so the loader's `fillDataRequest` loop can fall through
    /// to network without a suspension point on the cache check itself).
    /// Uses the same relaxed 50ms timing bound as the cache-hit test.
    @Test func cacheMiss_returnsNilSynchronously() {
        let store = CacheStore()
        let loader = CachingResourceLoader(
            videoId: "vid-miss",
            originalURL: URL(string: "https://ta.example.com/media/video.mp4")!,
            token: "test-token",
            store: store
        )
        let start = CFAbsoluteTimeGetCurrent()
        let data = loader.store.readData(videoId: "vid-miss", offset: 0, length: 4096)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        #expect(data == nil)
        #expect(elapsed < 0.05, "Sync cache miss took \(elapsed * 1000) ms — expected <50 ms")
    }

    // MARK: - Task 11 / B4 — Request dedup grace window

    /// The preloader is actively writing and its write head is within the
    /// `coverSoonWindow` (8 MB) of the requested offset. During the grace
    /// period the preloader publishes a chunk covering the request, so
    /// `waitForPreloaderData` must return that data — and crucially, the
    /// loader must NOT fall through to the network. We assert both halves:
    /// hit data is returned, and `MockURLProtocol.requestHandler` is never
    /// called (network hit count == 0).
    @Test func waitForPreloaderData_preloaderCatchesUp_skipsNetwork() async {
        // Install a mock URL session whose handler increments a counter if
        // ever called. The loader should NOT touch it — the whole point of
        // the dedup path is to avoid firing a duplicate network request.
        let config = MockResponse.makeConfiguration()
        let networkHits = NetworkHitCounter()
        MockURLProtocol.requestHandler = { _ in
            networkHits.bump()
            return (MockResponse.httpResponse(statusCode: 200), Data())
        }
        defer { MockResponse.tearDown() }

        // Seed the store with an entry but no chunks yet — simulating the
        // preloader having installed metadata and being actively downloading.
        //
        // NB: `CacheStore.readData` walks chunks assuming each one is exactly
        // `CacheStore.chunkSize` (512 KB) — the preloader always writes in
        // chunkSize slices. Our test fixture must preserve that invariant.
        let store = CacheStore()
        let videoId = "vid-dedup"
        let totalSize: Int64 = 50 * 1024 * 1024 // 50 MB plenty
        // 50 MB > prefixSize (8 MB) → both regions; main starts at 8 MB.
        // The dedup test cares about the file head (byte 0..1.5 MB), so we
        // write into `.prefix` and the request also lands inside it.
        store.setEntry(
            videoId: videoId,
            totalSize: totalSize,
            contentType: "video/mp4",
            resumeByte: 0
        )
        // Seed 2 × 512 KB chunks — prefix endOffset = 1 MB. Request at 1.5 MB
        // lands inside the next (soon-to-be-written) chunk range.
        let seedChunk = Data(repeating: 0xAA, count: CacheStore.chunkSize)
        _ = store.writeChunk(videoId: videoId, toRegion: .prefix, chunk: seedChunk)
        _ = store.writeChunk(videoId: videoId, toRegion: .prefix, chunk: seedChunk)

        let requestOffset: Int64 = Int64(CacheStore.chunkSize) * 3  // chunk index 3 (1.5 MB)
        let requestLength = 64 * 1024 // 64 KB — inside the chunk we'll write

        // Simulate the preloader: wait ~100 ms, then publish two more 512 KB
        // chunks covering the requested byte range. Use detached so the wait
        // runs in parallel with `waitForPreloaderData`.
        let storeRef = store
        Task.detached {
            try? await Task.sleep(for: .milliseconds(100))
            let catchUpChunk = Data(repeating: 0xBB, count: CacheStore.chunkSize)
            // Write chunk index 2 and chunk index 3 (so requestOffset at
            // index 3 is covered).
            _ = storeRef.writeChunk(videoId: videoId, toRegion: .prefix, chunk: catchUpChunk)
            _ = storeRef.writeChunk(videoId: videoId, toRegion: .prefix, chunk: catchUpChunk)
        }

        // Inject the loader with a deterministic `isPreloadingCheck` closure
        // returning `true` (no live preloader actor in this test). Use the
        // default real-time `graceSleep` — we only sleep ~3 × 200 ms max.
        let loader = CachingResourceLoader(
            videoId: videoId,
            originalURL: URL(string: "https://ta.example.com/media/vid-dedup.mp4")!,
            token: "test-token",
            sessionConfiguration: config,
            store: store,
            isPreloadingCheck: { _ in true }
        )

        let data = await loader.waitForPreloaderData(offset: requestOffset, length: requestLength)

        #expect(data != nil, "Grace loop should return data once preloader catches up")
        #expect(data?.count == requestLength)
        // The returned bytes must come from the freshly written chunk (0xBB).
        #expect(data?.first == 0xBB)
        #expect(networkHits.value == 0, "Network must not be touched during the grace window — preloader covers the request")
    }

    /// When the preloader is not active, `waitForPreloaderData` must return
    /// `nil` immediately so `fillDataRequest` falls through to the network
    /// without wasting the 600 ms grace budget.
    @Test func waitForPreloaderData_preloaderInactive_returnsNilImmediately() async {
        let store = CacheStore()
        let videoId = "vid-no-preload"
        store.setEntry(
            videoId: videoId,
            totalSize: 10 * 1024 * 1024,
            contentType: "video/mp4",
            resumeByte: 0
        )
        _ = store.writeChunk(videoId: videoId, toRegion: .prefix, chunk: Data(repeating: 0xCC, count: 1024))

        let loader = CachingResourceLoader(
            videoId: videoId,
            originalURL: URL(string: "https://ta.example.com/media/vid-no-preload.mp4")!,
            token: "test-token",
            store: store,
            isPreloadingCheck: { _ in false }
        )

        let start = CFAbsoluteTimeGetCurrent()
        let data = await loader.waitForPreloaderData(offset: 2048, length: 1024)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        #expect(data == nil)
        #expect(elapsed < 0.05, "Should return nil immediately without sleeping when preloader inactive; took \(elapsed * 1000) ms")
    }

    /// When the requested offset is beyond the `coverSoonWindow`, the grace
    /// loop gives up immediately — waiting ~600 ms for the preloader to
    /// cover 50 MB of ground would be a worse choice than just fetching.
    @Test func waitForPreloaderData_beyondCoverSoonWindow_returnsNilImmediately() async {
        let store = CacheStore()
        let videoId = "vid-far-ahead"
        store.setEntry(
            videoId: videoId,
            totalSize: 100 * 1024 * 1024,
            contentType: "video/mp4",
            resumeByte: 0
        )
        _ = store.writeChunk(videoId: videoId, toRegion: .prefix, chunk: Data(repeating: 0xDD, count: 1024))

        let loader = CachingResourceLoader(
            videoId: videoId,
            originalURL: URL(string: "https://ta.example.com/media/vid-far-ahead.mp4")!,
            token: "test-token",
            store: store,
            isPreloadingCheck: { _ in true }
        )

        // Request offset 50 MB — far beyond endOffset (~1 KB) + 8 MB window.
        let start = CFAbsoluteTimeGetCurrent()
        let data = await loader.waitForPreloaderData(offset: 50 * 1024 * 1024, length: 1024)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        #expect(data == nil)
        #expect(elapsed < 0.05, "Should return nil immediately when offset is outside coverSoonWindow; took \(elapsed * 1000) ms")
    }

    /// If the preloader is active and within the cover-soon window but never
    /// actually catches up during the grace budget, the helper returns `nil`
    /// so the caller can fall through to network. Uses an accelerated
    /// `graceSleep` stub so the test doesn't actually wait 600 ms.
    @Test func waitForPreloaderData_graceExhausted_returnsNil() async {
        let store = CacheStore()
        let videoId = "vid-slow-preload"
        store.setEntry(
            videoId: videoId,
            totalSize: 10 * 1024 * 1024,
            contentType: "video/mp4",
            resumeByte: 0
        )
        _ = store.writeChunk(videoId: videoId, toRegion: .prefix, chunk: Data(repeating: 0xEE, count: 1024))

        let loader = CachingResourceLoader(
            videoId: videoId,
            originalURL: URL(string: "https://ta.example.com/media/vid-slow.mp4")!,
            token: "test-token",
            store: store,
            isPreloadingCheck: { _ in true },
            graceSleep: { _ in /* instantly resolve — no real wait */ }
        )

        // Request 512 KB ahead of write head — within window, but the
        // simulated preloader never writes more data during the grace loop.
        let data = await loader.waitForPreloaderData(offset: 2048, length: 1024)
        #expect(data == nil, "Must return nil after grace attempts exhausted so caller falls through to network")
    }

    // MARK: - Region-aware serving (Task 4 of prefix-cache-region plan)

    /// Two regions seeded; offset falls inside the prefix range. The loader's
    /// hot-read path (`store.readData`) must return prefix data without any
    /// network involvement. `AVAssetResourceLoadingDataRequest` has no public
    /// initializer, so we verify the contract one layer down — the same
    /// pattern used by `cacheHit_readsSynchronously_fromInjectedStore`.
    @Test func serveRequest_offsetInPrefix_servedFromPrefix() {
        let store = CacheStore()
        let videoId = "vid-prefix-hit"
        // 50 MB total → prefixSize = 8 MB (lower bound), main starts at 8 MB.
        let totalSize: Int64 = 50 * 1024 * 1024
        store.setEntry(
            videoId: videoId,
            totalSize: totalSize,
            contentType: "video/mp4",
            resumeByte: 16 * 1024 * 1024 // resume at 16 MB — well past prefix end
        )
        let prefixByte: UInt8 = 0x11
        let prefixChunk = Data(repeating: prefixByte, count: CacheStore.chunkSize)
        // Write 4 × 512 KB into prefix → endOffset 2 MB.
        for _ in 0..<4 {
            _ = store.writeChunk(videoId: videoId, toRegion: .prefix, chunk: prefixChunk)
        }
        // Also write into main so we can confirm reads at prefix-range offsets
        // come from the prefix bytes (not from main, which starts at 16 MB).
        let mainByte: UInt8 = 0x22
        let mainChunk = Data(repeating: mainByte, count: CacheStore.chunkSize)
        _ = store.writeChunk(videoId: videoId, toRegion: .main, chunk: mainChunk)

        let loader = CachingResourceLoader(
            videoId: videoId,
            originalURL: URL(string: "https://ta.example.com/media/vid-prefix-hit.mp4")!,
            token: "test-token",
            store: store
        )

        // Request at 1 MB — inside prefix range, deep enough that one chunk's
        // worth (`length = 64 KB`) stays inside a single prefix chunk.
        let data = loader.store.readData(videoId: videoId, offset: 1 * 1024 * 1024, length: 64 * 1024)
        #expect(data != nil)
        #expect(data?.count == 64 * 1024)
        #expect(data?.first == prefixByte, "Read at prefix-range offset must return prefix bytes (0x11), not main bytes (0x22)")
    }

    /// Two regions seeded; offset falls in the main range. Reads return main
    /// region bytes.
    @Test func serveRequest_offsetInMain_servedFromMain() {
        let store = CacheStore()
        let videoId = "vid-main-hit"
        let totalSize: Int64 = 100 * 1024 * 1024 // 100 MB → prefixSize = 8 MB
        let mainStart: Int64 = 20 * 1024 * 1024 // resume at 20 MB → main starts there
        store.setEntry(
            videoId: videoId,
            totalSize: totalSize,
            contentType: "video/mp4",
            resumeByte: mainStart
        )

        let prefixByte: UInt8 = 0x33
        _ = store.writeChunk(videoId: videoId, toRegion: .prefix, chunk: Data(repeating: prefixByte, count: CacheStore.chunkSize))

        let mainByte: UInt8 = 0x44
        // Write a few main chunks starting at byte 20 MB.
        for _ in 0..<4 {
            _ = store.writeChunk(videoId: videoId, toRegion: .main, chunk: Data(repeating: mainByte, count: CacheStore.chunkSize))
        }

        let loader = CachingResourceLoader(
            videoId: videoId,
            originalURL: URL(string: "https://ta.example.com/media/vid-main-hit.mp4")!,
            token: "test-token",
            store: store
        )

        // Request inside main range — byte 21 MB (= mainStart + 1 MB).
        let offset: Int64 = mainStart + 1 * 1024 * 1024
        let data = loader.store.readData(videoId: videoId, offset: offset, length: 64 * 1024)
        #expect(data != nil)
        #expect(data?.count == 64 * 1024)
        #expect(data?.first == mainByte, "Read at main-range offset must return main bytes (0x44), not prefix bytes (0x33)")
    }

    /// Request straddles the prefix-region boundary. `CacheStore.readData`
    /// truncates the response to bytes available in the matched region (prefix
    /// in this case). The loader's `fillDataRequest` loop then issues a
    /// follow-up read for the remainder — verified here by reading the
    /// short response and confirming it matches prefix bytes only.
    ///
    /// AVAssetResourceLoadingDataRequest internally tracks `requestedLength`
    /// vs `currentOffset` — when `respond(with:)` is called with fewer bytes
    /// than requested, the framework re-issues by advancing `currentOffset`.
    /// Apple's `AVAssetResourceLoaderDelegate` documentation explicitly calls
    /// out that the delegate may respond with less than `requestedLength` and
    /// the framework will call back for more. So a short response is the
    /// supported partial-response contract.
    @Test func serveRequest_crossesBoundary_partialFromPrefix() {
        let store = CacheStore()
        let videoId = "vid-boundary"
        let totalSize: Int64 = 50 * 1024 * 1024
        store.setEntry(
            videoId: videoId,
            totalSize: totalSize,
            contentType: "video/mp4",
            resumeByte: 16 * 1024 * 1024
        )
        // Write a known number of prefix chunks (4 × 512 KB = 2 MB) so we
        // can reason about the prefix endOffset exactly. The prefix region's
        // *capacity* is the dynamic prefixSize (8 MB lower bound), but we
        // only need to fill enough to span the request range and have a
        // clean known boundary at `prefixEnd`.
        let prefixByte: UInt8 = 0x55
        let prefixChunkCount = 4
        for _ in 0..<prefixChunkCount {
            _ = store.writeChunk(videoId: videoId, toRegion: .prefix, chunk: Data(repeating: prefixByte, count: CacheStore.chunkSize))
        }
        let prefixEnd: Int64 = Int64(prefixChunkCount * CacheStore.chunkSize)  // exact: 4 × 512 KB = 2 MB
        // Write some main bytes (but they're at byte 16 MB, not adjacent to
        // prefix end at 2 MB, so the gap [2 MB .. 16 MB) is uncovered).
        _ = store.writeChunk(videoId: videoId, toRegion: .main, chunk: Data(repeating: 0x66, count: CacheStore.chunkSize))

        let loader = CachingResourceLoader(
            videoId: videoId,
            originalURL: URL(string: "https://ta.example.com/media/vid-boundary.mp4")!,
            token: "test-token",
            store: store
        )

        // Request 1 MB starting 256 KB before the prefix end (byte 2 MB).
        // Available in prefix: 256 KB. The request asks for 1 MB but only the
        // first 256 KB are inside the prefix region.
        let partialBytes = 256 * 1024
        let offset: Int64 = prefixEnd - Int64(partialBytes)
        let requestLength = 1 * 1024 * 1024  // 1 MB
        let data = loader.store.readData(videoId: videoId, offset: offset, length: requestLength)

        #expect(data != nil)
        // Must be SHORTER than requestLength — only the bytes inside prefix.
        #expect(data!.count == partialBytes, "Short response: only the 256 KB inside prefix range. AVPlayer issues a follow-up for the remainder.")
        #expect(data?.first == prefixByte)
        #expect(data?.last == prefixByte, "All returned bytes must be from prefix region (0x55)")
    }

    /// Both regions seeded but neither covers the requested offset (offset in
    /// the gap between prefix end and main start). The store returns `nil`,
    /// the dedup grace path also returns `nil` (offset is too far past prefix
    /// end), and the loader's `fillDataRequest` falls through to network. We
    /// exercise the store-miss / waitForPreloaderData-nil contract here; the
    /// full network-fallback path requires an `AVAssetResourceLoadingRequest`
    /// which has no public initializer.
    @Test func serveRequest_neitherRegionCovers_fallsToNetwork() async {
        let store = CacheStore()
        let videoId = "vid-gap"
        let totalSize: Int64 = 100 * 1024 * 1024 // 100 MB → prefix = 8 MB
        let mainStart: Int64 = 50 * 1024 * 1024  // huge gap [8 MB .. 50 MB)
        store.setEntry(
            videoId: videoId,
            totalSize: totalSize,
            contentType: "video/mp4",
            resumeByte: mainStart
        )
        _ = store.writeChunk(videoId: videoId, toRegion: .prefix, chunk: Data(repeating: 0x77, count: CacheStore.chunkSize))
        _ = store.writeChunk(videoId: videoId, toRegion: .main, chunk: Data(repeating: 0x88, count: CacheStore.chunkSize))

        let loader = CachingResourceLoader(
            videoId: videoId,
            originalURL: URL(string: "https://ta.example.com/media/vid-gap.mp4")!,
            token: "test-token",
            store: store,
            isPreloadingCheck: { _ in true },
            graceSleep: { _ in /* instant */ }
        )

        // Request at 30 MB — in the gap, no region covers it.
        let offset: Int64 = 30 * 1024 * 1024

        // Direct cache read returns nil.
        let cacheData = loader.store.readData(videoId: videoId, offset: offset, length: 1024)
        #expect(cacheData == nil)

        // The grace path also returns nil because:
        //   - prefix.endOffset = 512 KB → distance to 30 MB is way past coverSoonWindow
        //   - main.endOffset = mainStart + 512 KB ≈ 50.5 MB → offset 30 MB is
        //     BEFORE main's write head, so `offset >= endOffset` guard fails
        // Either way the helper returns nil so `fillDataRequest` falls through
        // to the network fetch path. (Test would require a real
        // AVAssetResourceLoadingDataRequest to drive the full flow — verifying
        // the grace-path nil is sufficient for this layer.)
        let graceData = await loader.waitForPreloaderData(offset: offset, length: 1024)
        #expect(graceData == nil, "Neither region covers offset; grace must yield to network fallback")
    }

    /// Region-aware grace: offset lies in the prefix range (and just past the
    /// prefix write head). The helper must use the **prefix** region's
    /// endOffset for the coverSoonWindow math, NOT main's (which is much
    /// further along at the resume byte). Without region awareness, the old
    /// code used `cacheStatus` → main's endOffset → `offset - main.endOffset`
    /// would be a large negative number, making `offset >= main.endOffset`
    /// false, returning `nil` immediately and falling through to network — the
    /// bug that this task fixes.
    @Test func waitForPreloaderData_offsetInPrefix_usesPrefixEndOffset() async {
        let store = CacheStore()
        let videoId = "vid-prefix-grace"
        let totalSize: Int64 = 1_000 * 1024 * 1024 // 1 GB → prefixSize = 10 MB
        let mainStart: Int64 = 500 * 1024 * 1024   // resume at 500 MB
        store.setEntry(
            videoId: videoId,
            totalSize: totalSize,
            contentType: "video/mp4",
            resumeByte: mainStart
        )
        // Seed prefix with 10 × 512 KB = 5 MB → prefix endOffset = 5 MB.
        let prefixChunk = Data(repeating: 0xAA, count: CacheStore.chunkSize)
        for _ in 0..<10 {
            _ = store.writeChunk(videoId: videoId, toRegion: .prefix, chunk: prefixChunk)
        }
        // Seed main with a few chunks too (simulates main downloading ahead).
        let mainChunk = Data(repeating: 0xBB, count: CacheStore.chunkSize)
        for _ in 0..<4 {
            _ = store.writeChunk(videoId: videoId, toRegion: .main, chunk: mainChunk)
        }

        // Verify the setup: prefix endOffset 5 MB, main endOffset 502 MB.
        let prefixStatus = store.regionStatus(videoId: videoId, region: .prefix)
        let mainStatus = store.regionStatus(videoId: videoId, region: .main)
        #expect(prefixStatus?.endOffset == Int64(5 * 1024 * 1024))
        #expect(mainStatus?.endOffset == mainStart + 4 * Int64(CacheStore.chunkSize))

        // Deterministic catch-up: use a custom `graceSleep` stub that performs
        // the writes synchronously when called. After the first sleep returns,
        // the prefix region will cover the requested offset. This avoids the
        // timing race of a detached writer + real-time sleep.
        let storeRef = store
        let didWrite = AtomicFlag()
        let injectedSleep: @Sendable (UInt64) async -> Void = { _ in
            if !didWrite.swap(true) {
                for _ in 0..<6 {
                    _ = storeRef.writeChunk(videoId: videoId, toRegion: .prefix, chunk: Data(repeating: 0xCC, count: CacheStore.chunkSize))
                }
            }
        }

        let loader = CachingResourceLoader(
            videoId: videoId,
            originalURL: URL(string: "https://ta.example.com/media/vid-prefix-grace.mp4")!,
            token: "test-token",
            store: store,
            isPreloadingCheck: { _ in true },
            graceSleep: injectedSleep
        )

        // Request offset 6 MB — 1 MB past prefix endOffset (5 MB). Within
        // coverSoonWindow (8 MB). With region-aware logic this is a valid
        // grace candidate. Without it, the helper would have consulted
        // `cacheStatus` (main only, endOffset ≈ 502 MB) and the
        // `offset >= main.endOffset` guard would be false → nil immediately.
        let requestOffset: Int64 = 6 * 1024 * 1024
        let requestLength = 64 * 1024
        let data = await loader.waitForPreloaderData(offset: requestOffset, length: requestLength)

        #expect(data != nil, "Region-aware grace must succeed when offset is in prefix range and prefix preloader catches up")
        #expect(data?.count == requestLength)
        // Bytes should come from the catch-up write (0xCC).
        #expect(data?.first == 0xCC)
    }

    // MARK: - Lifecycle / session invalidation

    @Test func deinit_invalidatesSession_withoutCrash() async {
        // Primary guarantee: releasing the loader (even with an outstanding
        // in-flight request) does not crash, and the session is torn down.
        let config = MockResponse.makeConfiguration()
        MockResponse.setUp(statusCode: 200, data: Data(repeating: 0xAB, count: 1024))

        weak var weakLoader: CachingResourceLoader?
        do {
            let loader = CachingResourceLoader(
                videoId: "vid-deinit",
                originalURL: URL(string: "https://ta.example.com/media/video.mp4")!,
                token: "test-token",
                sessionConfiguration: config
            )
            weakLoader = loader
            #expect(weakLoader != nil)
            // Keep `loader` alive only through end of scope.
            _ = loader.activeTaskCount()
        }
        // After scope exit, loader should be deallocated and session invalidated.
        // Sendable `weak var` may linger briefly; allow a short grace.
        for _ in 0..<20 {
            if weakLoader == nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(weakLoader == nil)
        MockResponse.tearDown()
    }
}
}

// MARK: - Test Helpers (file-private)

private final class CancelFlag: @unchecked Sendable {
    var value: Bool = false
}

/// Thread-safe one-shot flag used by region-aware grace tests to make the
/// catch-up write run exactly once on the first injected sleep, deterministic
/// across suite runs (no real-time waits → no race with the 600 ms grace
/// budget).
private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    /// Atomically set to `true`; returns the prior value.
    func swap(_ newValue: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let old = _value
        _value = newValue
        return old
    }
}

/// Thread-safe counter for verifying that the Task 11 / B4 dedup path does
/// not fall through to the network. Incremented from the `MockURLProtocol`
/// request handler (off main actor), read from the test (main actor).
private final class NetworkHitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func bump() {
        lock.lock(); defer { lock.unlock() }
        _value += 1
    }
}
