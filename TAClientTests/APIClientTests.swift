import Testing
import Foundation
@testable import TAClient

extension DataLayerSuite {
@Suite(.serialized) struct APIClientTests {

    init() {
        MockResponse.tearDown()
    }

    // MARK: - request<T> success

    @Test func request_decodesJSON() async throws {
        let (client, _) = MockResponse.makeAPIClient()
        MockResponse.setUp(json: ["response": "pong", "user": 1, "version": "0.4.10"])

        let result: PingDTO = try await client.request(endpoint: .ping)
        #expect(result.response == "pong")
        #expect(result.user == 1)
        #expect(result.version == "0.4.10")
    }

    // MARK: - Error mapping

    @Test func request_401_throwsUnauthorized() async {
        let (client, _) = MockResponse.makeAPIClient()
        MockResponse.setUp(statusCode: 401, json: ["detail": "Invalid token"])

        await #expect(throws: AppError.self) {
            let _: PingDTO = try await client.request(endpoint: .ping)
        }
    }

    @Test func request_403_throwsUnauthorized() async {
        let (client, _) = MockResponse.makeAPIClient()
        MockResponse.setUp(statusCode: 403, json: ["detail": "Forbidden"])

        do {
            let _: PingDTO = try await client.request(endpoint: .ping)
            Issue.record("Expected AppError.unauthorized")
        } catch let error as AppError {
            if case .unauthorized = error {} else {
                Issue.record("Expected .unauthorized, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - 403 ping probe (session resilience B)

    /// Shared 401/403-mapping assertion: runs `operation`, requires an
    /// `AppError` matching `matcher`, records an issue otherwise.
    private func expectAppError<T>(
        _ expected: String,
        sourceLocation: SourceLocation = #_sourceLocation,
        operation: () async throws -> T,
        matcher: (AppError) -> Bool
    ) async {
        do {
            _ = try await operation()
            Issue.record("Expected AppError.\(expected)", sourceLocation: sourceLocation)
        } catch let error as AppError {
            if !matcher(error) {
                Issue.record("Expected AppError.\(expected), got \(error)", sourceLocation: sourceLocation)
            }
        } catch {
            Issue.record("Unexpected error: \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test func request_403_pingAlive_throwsPermissionDenied() async {
        let (client, authState) = MockResponse.makeAPIClient()
        nonisolated(unsafe) var pingCount = 0
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/api/ping" {
                pingCount += 1
                return (MockResponse.httpResponse(statusCode: 200), MockResponse.json(["response": "pong", "user": 5]))
            }
            return (MockResponse.httpResponse(statusCode: 403), MockResponse.json(["detail": "Forbidden"]))
        }
        defer { MockResponse.tearDown() }

        await expectAppError("permissionDenied") {
            try await client.request(endpoint: .downloadList(page: 1, filter: "pending")) as Data
        } matcher: { error in
            if case .permissionDenied = error { return true }
            return false
        }
        #expect(pingCount == 1)
        #expect(authState.token == "test-token")
    }

    @Test func request_403_ping401_throwsUnauthorized() async {
        let (client, _) = MockResponse.makeAPIClient()
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/api/ping" {
                return (MockResponse.httpResponse(statusCode: 401), MockResponse.json(["detail": "Invalid token"]))
            }
            return (MockResponse.httpResponse(statusCode: 403), MockResponse.json(["detail": "Forbidden"]))
        }
        defer { MockResponse.tearDown() }

        await expectAppError("unauthorized") {
            try await client.request(endpoint: .downloadList(page: 1, filter: "pending")) as Data
        } matcher: { error in
            if case .unauthorized = error { return true }
            return false
        }
    }

    @Test func request_403_pingNetworkFail_throwsUnauthorized() async {
        let (client, _) = MockResponse.makeAPIClient()
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/api/ping" {
                throw URLError(.cannotConnectToHost)
            }
            return (MockResponse.httpResponse(statusCode: 403), MockResponse.json(["detail": "Forbidden"]))
        }
        defer { MockResponse.tearDown() }

        await expectAppError("unauthorized") {
            try await client.request(endpoint: .downloadList(page: 1, filter: "pending")) as Data
        } matcher: { error in
            if case .unauthorized = error { return true }
            return false
        }
    }

    @Test func request_403_pingNotPong_throwsUnauthorized() async {
        let (client, _) = MockResponse.makeAPIClient()
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/api/ping" {
                return (MockResponse.httpResponse(statusCode: 200), MockResponse.json(["response": "nope"]))
            }
            return (MockResponse.httpResponse(statusCode: 403), MockResponse.json(["detail": "Forbidden"]))
        }
        defer { MockResponse.tearDown() }

        await expectAppError("unauthorized") {
            try await client.request(endpoint: .downloadList(page: 1, filter: "pending")) as Data
        } matcher: { error in
            if case .unauthorized = error { return true }
            return false
        }
    }

    @Test func request_403_pingAnonymousUser_throwsUnauthorized() async {
        // pong WITHOUT an authenticated user means the token did not
        // authenticate — the probe must NOT report the token alive.
        let (client, _) = MockResponse.makeAPIClient()
        nonisolated(unsafe) var pingCount = 0
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/api/ping" {
                pingCount += 1
                return (MockResponse.httpResponse(statusCode: 200), MockResponse.json(["response": "pong", "user": 0]))
            }
            return (MockResponse.httpResponse(statusCode: 403), MockResponse.json(["detail": "Forbidden"]))
        }
        defer { MockResponse.tearDown() }

        await expectAppError("unauthorized") {
            try await client.request(endpoint: .downloadList(page: 1, filter: "pending")) as Data
        } matcher: { error in
            if case .unauthorized = error { return true }
            return false
        }
        #expect(pingCount == 1)
    }

    @Test func request_403_noTokenInFlight_skipsProbe_throwsUnauthorized() async {
        // Fixture: serverURL set, token nil — sentToken == nil so the stale
        // check is skipped; the 403 then reaches the probe, which short-
        // circuits without a token (pinging unauthenticated is meaningless)
        // → .unauthorized, and zero ping requests are issued.
        let keychain = KeychainService()
        keychain.clearAll()
        keychain.save("https://ta.example.com", for: .serverURL)
        let authState = AuthState(keychainService: keychain)
        let (client, _) = MockResponse.makeAPIClient(authState: authState)
        nonisolated(unsafe) var pingCount = 0
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/api/ping" {
                pingCount += 1
            }
            return (MockResponse.httpResponse(statusCode: 403), MockResponse.json(["detail": "Forbidden"]))
        }
        defer { MockResponse.tearDown() }

        await expectAppError("unauthorized") {
            try await client.request(endpoint: .downloadList(page: 1, filter: "pending")) as Data
        } matcher: { error in
            if case .unauthorized = error { return true }
            return false
        }
        #expect(pingCount == 0, "403 with nil sentToken must skip the probe — pinging without a token is meaningless")
    }

    @Test func request_401_doesNotPing() async {
        let (client, _) = MockResponse.makeAPIClient()
        nonisolated(unsafe) var pingCount = 0
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/api/ping" {
                pingCount += 1
            }
            return (MockResponse.httpResponse(statusCode: 401), MockResponse.json(["detail": "Invalid token"]))
        }
        defer { MockResponse.tearDown() }

        await #expect(throws: AppError.self) {
            let _: Data = try await client.request(endpoint: .downloadList(page: 1, filter: "pending"))
        }
        #expect(pingCount == 0)
    }

    @Test func request_403OnPingItself_throwsUnauthorized_noRecursion() async {
        let (client, _) = MockResponse.makeAPIClient()
        nonisolated(unsafe) var totalCount = 0
        MockURLProtocol.requestHandler = { _ in
            totalCount += 1
            return (MockResponse.httpResponse(statusCode: 403), MockResponse.json(["detail": "Forbidden"]))
        }
        defer { MockResponse.tearDown() }

        await expectAppError("unauthorized") {
            let _: PingDTO = try await client.request(endpoint: .ping)
        } matcher: { error in
            if case .unauthorized = error { return true }
            return false
        }
        #expect(totalCount == 1)
    }

    // MARK: - Stale-token door (session resilience E)

    @Test func request_401_tokenReplacedInFlight_throwsNetwork() async {
        let (client, authState) = MockResponse.makeAPIClient()
        let mutationDone = DispatchSemaphore(value: 0)
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/api/download" {
                // Simulate an in-flight server switch. Block the response
                // until the credential swap lands on MainActor — the test is
                // suspended awaiting, so MainActor is free and the swap is
                // guaranteed to precede the client's post-await token read.
                Task { @MainActor in
                    authState.setCredentials(token: "token-B", serverURL: "https://ta.example.com")
                    mutationDone.signal()
                }
                let signaled = mutationDone.wait(timeout: .now() + 5)
                // A false wait result means MainActor never ran the swap and
                // the test would silently exercise the non-stale path.
                if !signaled {
                    Issue.record("Credential swap semaphore timed out")
                }
            }
            return (MockResponse.httpResponse(statusCode: 401), MockResponse.json(["detail": "Invalid token"]))
        }
        defer {
            MockResponse.tearDown()
            // Restore the shared keychain fixture so later suites see
            // "test-token", not the in-flight "token-B" residue.
            KeychainService().save("test-token", for: .authToken)
        }

        await expectAppError("network") {
            let _: Data = try await client.request(endpoint: .downloadList(page: 1, filter: "pending"))
        } matcher: { error in
            if case .network = error { return true }
            return false
        }
    }

    @Test func request_403_tokenReplacedInFlight_throwsNetworkWithoutProbe() async {
        let (client, authState) = MockResponse.makeAPIClient()
        let mutationDone = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var pingCount = 0
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/api/ping" {
                pingCount += 1
                return (MockResponse.httpResponse(statusCode: 200), MockResponse.json(["response": "pong", "user": 1]))
            }
            Task { @MainActor in
                authState.setCredentials(token: "token-B", serverURL: "https://ta.example.com")
                mutationDone.signal()
            }
            let signaled = mutationDone.wait(timeout: .now() + 5)
            if !signaled {
                Issue.record("Credential swap semaphore timed out")
            }
            return (MockResponse.httpResponse(statusCode: 403), MockResponse.json(["detail": "Forbidden"]))
        }
        defer {
            MockResponse.tearDown()
            // Restore the shared keychain fixture so later suites see
            // "test-token", not the in-flight "token-B" residue.
            KeychainService().save("test-token", for: .authToken)
        }

        await expectAppError("network") {
            let _: Data = try await client.request(endpoint: .downloadList(page: 1, filter: "pending"))
        } matcher: { error in
            if case .network = error { return true }
            return false
        }
        #expect(pingCount == 0, "Stale check must run before the 403 ping probe")
    }

    @Test func request_403_tokenReplacedDuringProbe_throwsNetwork_notUnauthorized() async {
        // The credential swap lands while the ping probe is in flight (the
        // probe's "dead" verdict then applies to the OLD session). The post-
        // probe stale re-check must convert the would-be .unauthorized wipe
        // into a neutral .network. Deterministic for the same reason as the
        // in-flight tests above: the swap is enqueued on MainActor during
        // startLoading, and the client's post-probe token read resumes on
        // MainActor after it.
        let (client, authState) = MockResponse.makeAPIClient()
        let mutationDone = DispatchSemaphore(value: 0)
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/api/ping" {
                Task { @MainActor in
                    authState.setCredentials(token: "token-B", serverURL: "https://ta.example.com")
                    mutationDone.signal()
                }
                let signaled = mutationDone.wait(timeout: .now() + 5)
                if !signaled {
                    Issue.record("Credential swap semaphore timed out")
                }
                // Non-pong response → probe reports the token dead.
                return (MockResponse.httpResponse(statusCode: 200), MockResponse.json(["response": "nope"]))
            }
            return (MockResponse.httpResponse(statusCode: 403), MockResponse.json(["detail": "Forbidden"]))
        }
        defer {
            MockResponse.tearDown()
            // Restore the shared keychain fixture so later suites see
            // "test-token", not the in-flight "token-B" residue.
            KeychainService().save("test-token", for: .authToken)
        }

        await expectAppError("network") {
            let _: Data = try await client.request(endpoint: .downloadList(page: 1, filter: "pending"))
        } matcher: { error in
            if case .network = error { return true }
            return false
        }
    }

    @Test func request_401_sameToken_stillUnauthorized() async {
        let (client, _) = MockResponse.makeAPIClient()
        MockResponse.setUp(statusCode: 401, json: ["detail": "Invalid token"])
        defer { MockResponse.tearDown() }

        await expectAppError("unauthorized") {
            let _: Data = try await client.request(endpoint: .downloadList(page: 1, filter: "pending"))
        } matcher: { error in
            if case .unauthorized = error { return true }
            return false
        }
    }

    @Test func request_401_noTokenInFlight_skipsStaleCheck() async {
        // Fixture: serverURL set, token nil — the request goes out without an
        // Authorization header; sentToken == nil so the stale check is skipped
        // and the 401 maps to .unauthorized.
        let keychain = KeychainService()
        keychain.clearAll()
        keychain.save("https://ta.example.com", for: .serverURL)
        let authState = AuthState(keychainService: keychain)
        let (client, _) = MockResponse.makeAPIClient(authState: authState)
        MockResponse.setUp(statusCode: 401, json: ["detail": "Invalid token"])
        defer { MockResponse.tearDown() }

        await expectAppError("unauthorized") {
            let _: Data = try await client.request(endpoint: .downloadList(page: 1, filter: "pending"))
        } matcher: { error in
            if case .unauthorized = error { return true }
            return false
        }
    }

    @Test func request_500_throwsServerError() async {
        let (client, _) = MockResponse.makeAPIClient()
        MockResponse.setUp(statusCode: 500, json: ["detail": "Internal error"])

        do {
            let _: PingDTO = try await client.request(endpoint: .ping)
            Issue.record("Expected AppError.serverError")
        } catch let error as AppError {
            if case .serverError(let code, _) = error {
                #expect(code == 500)
            } else {
                Issue.record("Expected .serverError, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func request_invalidJSON_throwsDecoding() async {
        let (client, _) = MockResponse.makeAPIClient()
        MockResponse.setUp(statusCode: 200, data: Data("not json".utf8))

        do {
            let _: PingDTO = try await client.request(endpoint: .ping)
            Issue.record("Expected AppError.decoding")
        } catch let error as AppError {
            if case .decoding = error {} else {
                Issue.record("Expected .decoding, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func request_networkError_throwsNetwork() async {
        let (client, _) = MockResponse.makeAPIClient()
        MockResponse.setUpError(URLError(.notConnectedToInternet))

        do {
            let _: PingDTO = try await client.request(endpoint: .ping)
            Issue.record("Expected AppError.network")
        } catch let error as AppError {
            if case .network = error {} else {
                Issue.record("Expected .network, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func request_noBaseURL_throwsInvalidURL() async {
        let authState = MockResponse.makeAuthState(token: nil, serverURL: nil)
        let (client, _) = MockResponse.makeAPIClient(authState: authState)

        do {
            let _: PingDTO = try await client.request(endpoint: .ping)
            Issue.record("Expected AppError.invalidURL")
        } catch let error as AppError {
            if case .invalidURL = error {} else {
                Issue.record("Expected .invalidURL, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - requestVoid

    @Test func requestVoid_success() async throws {
        let (client, _) = MockResponse.makeAPIClient()
        MockResponse.setUp(statusCode: 200, data: Data())

        try await client.requestVoid(endpoint: .videoProgress(id: "vid1"), body: VideoProgressDTO(position: 42.0))
    }

    @Test func requestVoid_error_throws() async {
        let (client, _) = MockResponse.makeAPIClient()
        MockResponse.setUp(statusCode: 401, data: Data())

        await #expect(throws: AppError.self) {
            try await client.requestVoid(endpoint: .videoProgress(id: "vid1"))
        }
    }

    // MARK: - Auth header

    @Test func request_includesAuthHeader() async throws {
        let (client, _) = MockResponse.makeAPIClient()
        MockResponse.setUp(json: ["response": "pong"])

        let _: PingDTO = try await client.request(endpoint: .ping)

        let authHeader = MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization")
        #expect(authHeader == "Token test-token")
    }

    @Test func request_noToken_noAuthHeader() async throws {
        let authState = MockResponse.makeAuthState(token: nil, serverURL: nil)
        authState.setCredentials(token: "", serverURL: "https://ta.example.com")
        // Clear token only (set empty string via credentials, then nil out)
        let keychain = KeychainService()
        keychain.clearAll()
        let noTokenState = AuthState(keychainService: keychain)
        // serverURL set but no token
        // We need a custom approach: create authState with serverURL but no token
        // AuthState requires keychain, so we set serverURL in keychain only
        keychain.save("https://ta.example.com", for: .serverURL)
        let freshState = AuthState(keychainService: keychain)

        let (client, _) = MockResponse.makeAPIClient(authState: freshState)
        MockResponse.setUp(json: ["response": "pong"])

        let _: PingDTO = try await client.request(endpoint: .ping)

        let authHeader = MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization")
        #expect(authHeader == nil)

        // Cleanup
        keychain.clearAll()
    }

    // MARK: - Body encoding

    @Test func request_encodesBody() async throws {
        let (client, _) = MockResponse.makeAPIClient()
        MockResponse.setUp(statusCode: 200, data: Data())

        try await client.requestVoid(
            endpoint: .videoProgress(id: "vid1"),
            body: VideoProgressDTO(position: 123.5)
        )

        guard let bodyData = MockURLProtocol.lastRequestBody else {
            Issue.record("Expected request body to be captured")
            return
        }
        let json = try JSONSerialization.jsonObject(with: bodyData) as! [String: Any]
        #expect(json["position"] as? Double == 123.5)
    }

    // MARK: - Query items in URL

    @Test func request_includesQueryItems() async throws {
        let (client, _) = MockResponse.makeAPIClient()
        MockResponse.setUp(json: ["data": [], "paginate": nil] as [String: Any?])

        let _: VideoListResponseDTO = try await client.request(
            endpoint: .videoList(page: 2, sort: "views", order: "asc", watch: nil, channel: nil, vidType: nil)
        )

        guard let url = MockURLProtocol.lastRequest?.url else {
            Issue.record("Expected lastRequest URL to be set")
            return
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "page", value: "2")))
        #expect(items.contains(URLQueryItem(name: "sort", value: "views")))
        #expect(items.contains(URLQueryItem(name: "order", value: "asc")))
    }

    // MARK: - Login

    @Test func login_success_returnsToken() async throws {
        let (client, _) = MockResponse.makeAPIClient()
        var callCount = 0
        MockURLProtocol.requestHandler = { request in
            callCount += 1
            if callCount == 1 {
                // Step 1: login
                return (MockResponse.httpResponse(statusCode: 200), Data())
            } else {
                // Step 2: token
                return (MockResponse.httpResponse(statusCode: 200), MockResponse.json(["token": "abc-token-123"]))
            }
        }

        let token = try await client.login(
            serverURL: URL(string: "https://ta.example.com")!,
            username: "user",
            password: "pass"
        )
        #expect(token == "abc-token-123")
    }

    @Test func login_step1Fails_throwsServerError() async {
        let (client, _) = MockResponse.makeAPIClient()
        MockURLProtocol.requestHandler = { _ in
            (MockResponse.httpResponse(statusCode: 401), Data())
        }

        do {
            _ = try await client.login(
                serverURL: URL(string: "https://ta.example.com")!,
                username: "user",
                password: "wrong"
            )
            Issue.record("Expected error")
        } catch let error as AppError {
            if case .serverError = error {} else {
                Issue.record("Expected .serverError, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func login_networkError_throwsNetwork() async {
        let (client, _) = MockResponse.makeAPIClient()
        MockResponse.setUpError(URLError(.timedOut))

        do {
            _ = try await client.login(
                serverURL: URL(string: "https://ta.example.com")!,
                username: "user",
                password: "pass"
            )
            Issue.record("Expected error")
        } catch let error as AppError {
            if case .network = error {} else {
                Issue.record("Expected .network, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
}
