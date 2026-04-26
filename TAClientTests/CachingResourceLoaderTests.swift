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
        store.setEntry(
            videoId: videoId,
            startOffset: 0,
            totalSize: Int64(payload.count),
            contentType: "video/mp4"
        )
        _ = store.writeChunk(videoId: videoId, chunk: payload)

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
        store.setEntry(
            videoId: videoId,
            startOffset: 0,
            totalSize: totalSize,
            contentType: "video/mp4"
        )
        // Seed 2 × 512 KB chunks — endOffset = 1 MB. Request at 1.5 MB lands
        // inside the next (soon-to-be-written) chunk range.
        let seedChunk = Data(repeating: 0xAA, count: CacheStore.chunkSize)
        _ = store.writeChunk(videoId: videoId, chunk: seedChunk)
        _ = store.writeChunk(videoId: videoId, chunk: seedChunk)

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
            _ = storeRef.writeChunk(videoId: videoId, chunk: catchUpChunk)
            _ = storeRef.writeChunk(videoId: videoId, chunk: catchUpChunk)
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
            startOffset: 0,
            totalSize: 10 * 1024 * 1024,
            contentType: "video/mp4"
        )
        _ = store.writeChunk(videoId: videoId, chunk: Data(repeating: 0xCC, count: 1024))

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
            startOffset: 0,
            totalSize: 100 * 1024 * 1024,
            contentType: "video/mp4"
        )
        _ = store.writeChunk(videoId: videoId, chunk: Data(repeating: 0xDD, count: 1024))

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
            startOffset: 0,
            totalSize: 10 * 1024 * 1024,
            contentType: "video/mp4"
        )
        _ = store.writeChunk(videoId: videoId, chunk: Data(repeating: 0xEE, count: 1024))

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
