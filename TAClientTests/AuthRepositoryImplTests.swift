import Testing
import Foundation
@testable import TAClient

extension DataLayerSuite {
@Suite(.serialized) struct AuthRepositoryImplTests {

    init() {
        MockResponse.tearDown()
    }

    private func makeRepo() -> (AuthRepositoryImpl, AuthState) {
        let (client, authState) = MockResponse.makeAPIClient()
        let repo = AuthRepositoryImpl(apiClient: client, authState: authState)
        return (repo, authState)
    }

    // MARK: - URL Normalization

    @Test func login_addsHttps() async throws {
        let (repo, authState) = makeRepo()
        var callCount = 0
        MockURLProtocol.requestHandler = { request in
            callCount += 1
            if callCount == 1 {
                return (MockResponse.httpResponse(statusCode: 200), Data())
            } else {
                return (MockResponse.httpResponse(statusCode: 200), MockResponse.json(["token": "tok"]))
            }
        }

        try await repo.login(serverURL: "ta.example.com", username: "u", password: "p")
        #expect(authState.serverURL == "https://ta.example.com")
        authState.handleUnauthorized()
    }

    @Test func login_removesTrailingSlash() async throws {
        let (repo, authState) = makeRepo()
        var callCount = 0
        MockURLProtocol.requestHandler = { request in
            callCount += 1
            if callCount == 1 {
                return (MockResponse.httpResponse(statusCode: 200), Data())
            } else {
                return (MockResponse.httpResponse(statusCode: 200), MockResponse.json(["token": "tok"]))
            }
        }

        try await repo.login(serverURL: "https://ta.example.com/", username: "u", password: "p")
        #expect(authState.serverURL == "https://ta.example.com")
        authState.handleUnauthorized()
    }

    @Test func login_trimsWhitespace() async throws {
        let (repo, authState) = makeRepo()
        var callCount = 0
        MockURLProtocol.requestHandler = { request in
            callCount += 1
            if callCount == 1 {
                return (MockResponse.httpResponse(statusCode: 200), Data())
            } else {
                return (MockResponse.httpResponse(statusCode: 200), MockResponse.json(["token": "tok"]))
            }
        }

        try await repo.login(serverURL: "  https://ta.example.com  ", username: "u", password: "p")
        #expect(authState.serverURL == "https://ta.example.com")
        authState.handleUnauthorized()
    }

    @Test func login_preservesHttp() async throws {
        let (repo, authState) = makeRepo()
        var callCount = 0
        MockURLProtocol.requestHandler = { request in
            callCount += 1
            if callCount == 1 {
                return (MockResponse.httpResponse(statusCode: 200), Data())
            } else {
                return (MockResponse.httpResponse(statusCode: 200), MockResponse.json(["token": "tok"]))
            }
        }

        try await repo.login(serverURL: "http://local.dev", username: "u", password: "p")
        #expect(authState.serverURL == "http://local.dev")
        authState.handleUnauthorized()
    }

    // MARK: - Login credentials

    @Test func login_success_storesCredentials() async throws {
        let (repo, authState) = makeRepo()
        var callCount = 0
        MockURLProtocol.requestHandler = { request in
            callCount += 1
            if callCount == 1 {
                return (MockResponse.httpResponse(statusCode: 200), Data())
            } else {
                return (MockResponse.httpResponse(statusCode: 200), MockResponse.json(["token": "my-token"]))
            }
        }

        try await repo.login(serverURL: "https://ta.example.com", username: "u", password: "p")
        #expect(authState.token == "my-token")
        #expect(authState.serverURL == "https://ta.example.com")
        #expect(authState.isAuthenticated == true)
        authState.handleUnauthorized()
    }

    @Test func login_failure_doesNotStoreCredentials() async {
        let authState = MockResponse.makeAuthState(token: nil, serverURL: nil)
        let (client, _) = MockResponse.makeAPIClient(authState: authState)
        let repo = AuthRepositoryImpl(apiClient: client, authState: authState)

        MockURLProtocol.requestHandler = { _ in
            (MockResponse.httpResponse(statusCode: 401), Data())
        }

        do {
            try await repo.login(serverURL: "https://ta.example.com", username: "u", password: "wrong")
        } catch {}

        #expect(authState.token == nil)
        #expect(authState.isAuthenticated == false)
    }

    // MARK: - Ping

    @Test func ping_pong_returnsTrue() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(json: ["response": "pong", "user": 1, "version": "0.4.10"])

        let result = try await repo.ping()
        #expect(result == true)
        authState.handleUnauthorized()
    }

    @Test func ping_notPong_returnsFalse() async throws {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(json: ["response": "something-else"])

        let result = try await repo.ping()
        #expect(result == false)
        authState.handleUnauthorized()
    }

    @Test func ping_401_throwsUnauthorized() async {
        let (repo, authState) = makeRepo()
        MockResponse.setUp(statusCode: 401, json: ["detail": "Invalid token"])

        await #expect(throws: AppError.self) {
            _ = try await repo.ping()
        }
        authState.handleUnauthorized()
    }

    // MARK: - Logout

    @Test func logout_clearsAuthState() {
        let (repo, authState) = makeRepo()
        #expect(authState.isAuthenticated == true)

        repo.logout()

        #expect(authState.token == nil)
        #expect(authState.serverURL == nil)
        #expect(authState.isAuthenticated == false)
    }
}
}
