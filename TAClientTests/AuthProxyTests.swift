import Testing
import Foundation
@testable import TAClient

/// The auth proxy listens on the local network (AirPlay receivers must reach
/// it), so every URL carries a per-instance path secret and requests without
/// it must never reach the server with the user's token.
struct AuthProxyTests {

    // MARK: - upstreamPath

    @Test func upstreamPath_withSecret_stripsSecret() {
        let path = AuthProxy.upstreamPath(forRequestTarget: "/abc/media/UC1/vid.mp4?x=1", secret: "abc")
        #expect(path == "/media/UC1/vid.mp4?x=1")
    }

    @Test func upstreamPath_withoutSecret_isRejected() {
        #expect(AuthProxy.upstreamPath(forRequestTarget: "/media/UC1/vid.mp4", secret: "abc") == nil)
    }

    @Test func upstreamPath_wrongSecret_isRejected() {
        #expect(AuthProxy.upstreamPath(forRequestTarget: "/abd/media/vid.mp4", secret: "abc") == nil)
    }

    @Test func upstreamPath_secretWithoutTrailingSlash_isRejected() {
        #expect(AuthProxy.upstreamPath(forRequestTarget: "/abcmedia/vid.mp4", secret: "abc") == nil)
        #expect(AuthProxy.upstreamPath(forRequestTarget: "/abc", secret: "abc") == nil)
    }

    @Test func upstreamPath_absoluteFormTarget_isRejected() {
        let target = "http://evil.example.com/abc/media/vid.mp4"
        #expect(AuthProxy.upstreamPath(forRequestTarget: target, secret: "abc") == nil)
    }

    // MARK: - URLs

    @Test func proxyURL_beforeStart_isNil() async {
        let proxy = AuthProxy(token: "t", serverBaseURL: URL(string: "https://ta.example.com")!)
        let url = await proxy.proxyURL(for: URL(string: "https://ta.example.com/media/vid.mp4")!)
        #expect(url == nil)
    }

    @Test func proxyURL_isLoopbackWithSecretPrefixAndQuery() async throws {
        let proxy = AuthProxy(token: "t", serverBaseURL: URL(string: "https://ta.example.com")!)
        try await proxy.start()
        defer { Task { await proxy.stop() } }

        let original = URL(string: "https://ta.example.com/media/UC1/vid%20a.mp4?x=1")!
        let url = try #require(await proxy.proxyURL(for: original))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(components.scheme == "http")
        #expect(components.host == "127.0.0.1")
        #expect((components.port ?? 0) > 0)
        #expect(components.percentEncodedPath.hasSuffix("/media/UC1/vid%20a.mp4"))
        #expect(components.percentEncodedPath != "/media/UC1/vid%20a.mp4")
        #expect(components.percentEncodedQuery == "x=1")
    }

    @Test func networkURL_usesLocalNetworkHost() async throws {
        let proxy = AuthProxy(token: "t", serverBaseURL: URL(string: "https://ta.example.com")!)
        try await proxy.start()
        defer { Task { await proxy.stop() } }

        let original = URL(string: "https://ta.example.com/media/vid.mp4")!
        let url = await proxy.networkURL(for: original)
        if let address = AuthProxy.localNetworkIPv4Address() {
            #expect(url?.host == address)
            #expect(url?.path.hasSuffix("/media/vid.mp4") == true)
        } else {
            #expect(url == nil)
        }
    }

    @Test func requestWithoutSecret_isRefusedWith404() async throws {
        let proxy = AuthProxy(token: "t", serverBaseURL: URL(string: "https://ta.example.com")!)
        try await proxy.start()
        defer { Task { await proxy.stop() } }

        let port = await proxy.localPort
        let bare = URL(string: "http://127.0.0.1:\(port)/media/vid.mp4")!
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let (_, response) = try await session.data(from: bare)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
    }
}
