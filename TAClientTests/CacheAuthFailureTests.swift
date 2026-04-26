import Testing
import Foundation
@testable import TAClient

/// Tests for B3 (Task 3): the preloader (`VideoCachePreloader`) and
/// `CachingResourceLoader` must dispatch a `.taAuthUnauthorized` notification
/// when the Data-layer request receives 401/403. `AppRouter` subscribes to
/// this and drops the user back to the login screen.
extension DataLayerSuite {
@Suite(.serialized) struct CacheAuthFailureTests {

    init() {
        MockResponse.tearDown()
        VideoCachePreloader.testSessionConfigurationOverride = nil
    }

    // MARK: - VideoCachePreloader

    @Test func videoCacheDownload_on401_postsUnauthorizedNotification() async {
        // Install mock URL protocol that returns 401 for any request.
        VideoCachePreloader.testSessionConfigurationOverride = MockResponse.makeConfiguration()
        MockResponse.setUp(statusCode: 401, data: Data())
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        // Clear any previous cache entry so the preload actually runs.
        await VideoCachePreloader.shared.clear()

        // Subscribe BEFORE triggering the download so we don't miss the post.
        // Scope by senderId so a prior test's stray post doesn't fire this.
        let expectation = NotificationExpectation(
            name: .taAuthUnauthorized,
            senderId: "vid-401-preload"
        )

        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: "vid-401-preload",
            url: URL(string: "https://ta.example.com/media/vid-401.mp4")!,
            token: "test-token",
            startPosition: 0,
            duration: 0,
            maxRetries: 0
        )

        let fired = await expectation.wait(timeoutSeconds: 5)
        #expect(fired, "Expected .taAuthUnauthorized notification after 401 response from preloader")
    }

    @Test func videoCacheDownload_on403_postsUnauthorizedNotification() async {
        VideoCachePreloader.testSessionConfigurationOverride = MockResponse.makeConfiguration()
        MockResponse.setUp(statusCode: 403, data: Data())
        defer {
            VideoCachePreloader.testSessionConfigurationOverride = nil
            MockResponse.tearDown()
        }

        await VideoCachePreloader.shared.clear()

        let expectation = NotificationExpectation(
            name: .taAuthUnauthorized,
            senderId: "vid-403-preload"
        )

        await VideoCachePreloader.shared.startPreloadWithRetry(
            videoId: "vid-403-preload",
            url: URL(string: "https://ta.example.com/media/vid-403.mp4")!,
            token: "test-token",
            startPosition: 0,
            duration: 0,
            maxRetries: 0
        )

        let fired = await expectation.wait(timeoutSeconds: 5)
        #expect(fired, "Expected .taAuthUnauthorized notification after 403 response from preloader")
    }

    // MARK: - CachingResourceLoader

    @Test func cachingResourceLoader_on401_postsUnauthorizedNotification() async {
        // CachingResourceLoader accepts a sessionConfiguration for the network
        // session so we inject a mock configuration directly. The 401/403
        // detection path is centralised in `handleUnauthorizedIfNeeded`, which
        // both `fillContentInfo` and `fetchFromNetwork` invoke. We verify it
        // fires the notification for a 401 response.
        let loader = CachingResourceLoader(
            videoId: "vid-401-loader",
            originalURL: URL(string: "https://ta.example.com/media/vid-401-loader.mp4")!,
            token: "test-token"
        )

        let expectation = NotificationExpectation(
            name: .taAuthUnauthorized,
            senderId: "vid-401-loader"
        )

        let http401 = HTTPURLResponse(
            url: URL(string: "https://ta.example.com/media/vid-401-loader.mp4")!,
            statusCode: 401,
            httpVersion: nil,
            headerFields: nil
        )!
        let wasUnauthorized = loader.handleUnauthorizedIfNeeded(response: http401)
        #expect(wasUnauthorized, "handleUnauthorizedIfNeeded should detect 401 as unauthorized")

        let fired = await expectation.wait(timeoutSeconds: 2)
        #expect(fired, "Expected .taAuthUnauthorized notification after 401 response from loader")
    }

    @Test func cachingResourceLoader_on403_postsUnauthorizedNotification() async {
        let loader = CachingResourceLoader(
            videoId: "vid-403-loader",
            originalURL: URL(string: "https://ta.example.com/media/vid-403-loader.mp4")!,
            token: "test-token"
        )

        let expectation = NotificationExpectation(
            name: .taAuthUnauthorized,
            senderId: "vid-403-loader"
        )

        let http403 = HTTPURLResponse(
            url: URL(string: "https://ta.example.com/media/vid-403-loader.mp4")!,
            statusCode: 403,
            httpVersion: nil,
            headerFields: nil
        )!
        let wasUnauthorized = loader.handleUnauthorizedIfNeeded(response: http403)
        #expect(wasUnauthorized, "handleUnauthorizedIfNeeded should detect 403 as unauthorized")

        let fired = await expectation.wait(timeoutSeconds: 2)
        #expect(fired, "Expected .taAuthUnauthorized notification after 403 response from loader")
    }

    @Test func cachingResourceLoader_on200_doesNotPostUnauthorized() async {
        let loader = CachingResourceLoader(
            videoId: "vid-ok-loader",
            originalURL: URL(string: "https://ta.example.com/media/vid-ok-loader.mp4")!,
            token: "test-token"
        )

        // Scope the observer by senderId (this loader's videoId) so any
        // stray `.taAuthUnauthorized` posts from a prior test's async
        // teardown — which carry their own videoId as `object` — are
        // filtered out and can't trip this assertion.
        let expectation = NotificationExpectation(
            name: .taAuthUnauthorized,
            senderId: "vid-ok-loader"
        )

        let http200 = HTTPURLResponse(
            url: URL(string: "https://ta.example.com/media/vid-ok-loader.mp4")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let wasUnauthorized = loader.handleUnauthorizedIfNeeded(response: http200)
        #expect(!wasUnauthorized, "handleUnauthorizedIfNeeded should not treat 200 as unauthorized")

        // Give any stray posts a moment to arrive.
        let fired = await expectation.wait(timeoutSeconds: 0.3)
        #expect(!fired, "No notification should fire on 200 response")
    }

    // MARK: - AppRouter integration

    @Test @MainActor func appRouter_onUnauthorizedNotification_transitionsToLogin() async {
        let keychain = KeychainService()
        keychain.clearAll()
        let authState = AuthState(keychainService: keychain)
        authState.setCredentials(token: "tok", serverURL: "https://ta.example.com")
        let router = AppRouter(authState: authState)
        #expect(router.appState != .login)

        NotificationCenter.default.post(name: .taAuthUnauthorized, object: nil)

        // Give the main-queue notification a tick to drain.
        for _ in 0..<50 {
            if router.appState == .login { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(router.appState == .login)
    }

    @Test @MainActor func appRouter_handleUnauthorized_isIdempotent() async {
        let keychain = KeychainService()
        keychain.clearAll()
        let authState = AuthState(keychainService: keychain)
        authState.setCredentials(token: "tok", serverURL: "https://ta.example.com")
        let router = AppRouter(authState: authState)

        // Rapid-fire multiple posts — must only transition once, no crashes.
        for _ in 0..<5 {
            NotificationCenter.default.post(name: .taAuthUnauthorized, object: nil)
        }

        for _ in 0..<50 {
            if router.appState == .login { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(router.appState == .login)

        // After onLoginSuccess, the idempotency flag resets so a subsequent
        // 401 after re-login will again transition.
        router.onLoginSuccess()
        #expect(router.appState == .authenticated)

        NotificationCenter.default.post(name: .taAuthUnauthorized, object: nil)
        for _ in 0..<50 {
            if router.appState == .login { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(router.appState == .login)
    }
}
}

// MARK: - NotificationExpectation helper

/// Minimal async expectation for a single `Notification.Name` post. Subscribes
/// on instantiation so tests don't race between post and subscribe.
///
/// Pass `senderId` to scope the observer to a specific `object:` value
/// (the posters send the target videoId) — this prevents cross-test bleed
/// when a prior test's async teardown posts `.taAuthUnauthorized` after
/// this test has already subscribed.
private final class NotificationExpectation: @unchecked Sendable {
    private let lock = NSLock()
    private var didFire = false
    private var token: NSObjectProtocol?

    init(name: Notification.Name, senderId: String? = nil) {
        token = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            // If the test supplied a senderId, only match notifications
            // whose `object` is that string. Ignore everything else —
            // including notifications from prior tests still draining.
            if let senderId {
                guard (note.object as? String) == senderId else { return }
            }
            self.lock.lock()
            self.didFire = true
            self.lock.unlock()
        }
    }

    deinit {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func wait(timeoutSeconds: Double) async -> Bool {
        let step: UInt64 = 20_000_000 // 20 ms in nanoseconds
        let iterations = Int((timeoutSeconds * 1_000_000_000) / Double(step))
        for _ in 0..<iterations {
            lock.lock()
            let fired = didFire
            lock.unlock()
            if fired { return true }
            try? await Task.sleep(nanoseconds: step)
        }
        lock.lock()
        defer { lock.unlock() }
        return didFire
    }
}
