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
