import Foundation

final class APIClient {
    private static let decoder = JSONDecoder()

    private let authState: AuthState
    private let session: URLSession
    private let loginSession: URLSession

    init(
        authState: AuthState,
        configuration: URLSessionConfiguration = .default,
        loginConfiguration: URLSessionConfiguration = .default
    ) {
        self.authState = authState

        configuration.timeoutIntervalForRequest = 30
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)

        loginConfiguration.httpCookieStorage = HTTPCookieStorage.shared
        loginConfiguration.httpCookieAcceptPolicy = .always
        self.loginSession = URLSession(configuration: loginConfiguration)
    }

    func request<T: Decodable>(
        endpoint: APIEndpoint,
        body: (any Encodable)? = nil,
        baseURL: URL? = nil
    ) async throws -> T {
        let data = try await rawRequest(endpoint: endpoint, body: body, baseURL: baseURL)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw AppError.decoding(underlying: error)
        }
    }

    func requestVoid(
        endpoint: APIEndpoint,
        body: (any Encodable)? = nil,
        baseURL: URL? = nil
    ) async throws {
        _ = try await rawRequest(endpoint: endpoint, body: body, baseURL: baseURL)
    }

    private func rawRequest(
        endpoint: APIEndpoint,
        body: (any Encodable)? = nil,
        baseURL: URL? = nil
    ) async throws -> Data {
        let base = baseURL ?? authState.baseURL
        guard let base else {
            throw AppError.invalidURL
        }

        var components = URLComponents(url: base.appendingPathComponent(endpoint.path), resolvingAgainstBaseURL: false)
        components?.queryItems = endpoint.queryItems

        guard let url = components?.url else {
            throw AppError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Snapshot the token that identifies THIS connection. A 401/403 that
        // arrives after the credentials were replaced (in-flight server
        // switch) belongs to a dead session and must not revoke the live one.
        let sentToken = authState.token

        if let sentToken {
            request.setValue("Token \(sentToken)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AppError.network(underlying: error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.network(underlying: nil)
        }

        switch httpResponse.statusCode {
        case 200...299:
            return data
        case 401, 403:
            // Stale-token guard: a late 401/403 from a request carrying a
            // since-replaced token must not revoke the live session — die
            // neutrally instead (banner, no logout), before any probe.
            if let sentToken, sentToken != authState.token {
                throw AppError.network(underlying: nil)
            }
            // A 403 with a still-valid token means "authenticated but not
            // allowed" (e.g. non-admin hitting an admin endpoint) — surface
            // it as a plain error banner instead of wiping the session.
            // Verify with a direct ping probe; the ping endpoint itself is
            // exempt to avoid recursion.
            if httpResponse.statusCode == 401 {
                throw AppError.unauthorized
            }
            if case .ping = endpoint {
                throw AppError.unauthorized
            }
            let probeAlive = await probeTokenAlive(baseURL: base)
            if probeAlive {
                throw AppError.permissionDenied
            }
            // The probe can race a credential swap: if the token changed
            // while the probe was in flight, its "dead" verdict applies to
            // the OLD session — wiping now would revoke the fresh one.
            if let sentToken, sentToken != authState.token {
                throw AppError.network(underlying: nil)
            }
            throw AppError.unauthorized
        default:
            let message = String(data: data, encoding: .utf8)
            throw AppError.serverError(statusCode: httpResponse.statusCode, message: message)
        }
    }

    /// Direct `GET /api/ping/` with the current token — deliberately not
    /// routed through `request<T>` (a 403 there would recurse back into the
    /// probe). Returns true only when the server confirms the token is alive
    /// (pong + authenticated user); every failure mode means the session is
    /// dead and maps to `AppError.unauthorized`.
    ///
    /// - Transient probe failure (network blip) also collapses to
    ///   `.unauthorized` → session wipe. Accepted trade-off: a 403 is rare,
    ///   the wipe is recoverable via re-login, and treating a dead probe as
    ///   "permission denied" would strand users with a revoked session.
    /// - Validity here is deliberately stricter than `AuthRepositoryImpl.ping()`
    ///   (pong alone): only a pong WITH an authenticated user proves the token
    ///   is alive; an anonymous pong (user absent/0) means the token didn't
    ///   authenticate. The two must not be unified.
    /// - Reuses the shared `session` (30s timeout) rather than a dedicated
    ///   short-timeout session to avoid a second URLSession lifecycle; the
    ///   per-request timeout below bounds the probe.
    private func probeTokenAlive(baseURL: URL) async -> Bool {
        guard let token = authState.token else {
            return false
        }

        var request = URLRequest(url: baseURL.appendingPathComponent(APIEndpoint.ping.path))
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let dto = try? Self.decoder.decode(PingDTO.self, from: data)
        else {
            return false
        }
        return dto.response == "pong" && (dto.user ?? 0) > 0
    }

    // MARK: - Login (2-step with cookies)

    func login(serverURL: URL, username: String, password: String) async throws -> String {
        // Step 1: POST login to get session cookie
        let loginURL = serverURL.appendingPathComponent("/api/user/login/")
        var loginRequest = URLRequest(url: loginURL)
        loginRequest.httpMethod = "POST"
        loginRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let loginBody = LoginRequestDTO(username: username, password: password)
        loginRequest.httpBody = try JSONEncoder().encode(loginBody)

        let (_, loginResponse): (Data, URLResponse)
        do {
            (_, loginResponse) = try await loginSession.data(for: loginRequest)
        } catch {
            throw AppError.network(underlying: error)
        }

        guard let httpLoginResponse = loginResponse as? HTTPURLResponse else {
            throw AppError.network(underlying: nil)
        }

        guard (200...299).contains(httpLoginResponse.statusCode) else {
            throw AppError.serverError(
                statusCode: httpLoginResponse.statusCode,
                message: "Login failed"
            )
        }

        // Step 2: GET token using session cookie
        let tokenURL = serverURL.appendingPathComponent("/api/appsettings/token/")
        var tokenRequest = URLRequest(url: tokenURL)
        tokenRequest.httpMethod = "GET"

        let (tokenData, tokenResponse): (Data, URLResponse)
        do {
            (tokenData, tokenResponse) = try await loginSession.data(for: tokenRequest)
        } catch {
            throw AppError.network(underlying: error)
        }

        guard let httpTokenResponse = tokenResponse as? HTTPURLResponse,
              (200...299).contains(httpTokenResponse.statusCode) else {
            throw AppError.serverError(statusCode: 0, message: "Failed to retrieve token")
        }

        let tokenDTO = try Self.decoder.decode(TokenResponseDTO.self, from: tokenData)

        // Clear session cookies so they don't leak into subsequent logins to different servers
        if let cookies = loginSession.configuration.httpCookieStorage?.cookies(for: serverURL) {
            for cookie in cookies {
                loginSession.configuration.httpCookieStorage?.deleteCookie(cookie)
            }
        }

        return tokenDTO.token
    }
}
