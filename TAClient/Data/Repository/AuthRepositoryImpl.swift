import Foundation

final class AuthRepositoryImpl: AuthRepositoryProtocol {
    private let apiClient: APIClient
    private let authState: AuthState

    init(apiClient: APIClient, authState: AuthState) {
        self.apiClient = apiClient
        self.authState = authState
    }

    func login(serverURL: String, username: String, password: String) async throws {
        var normalizedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedURL.hasSuffix("/") {
            normalizedURL = String(normalizedURL.dropLast())
        }
        if !normalizedURL.hasPrefix("http://") && !normalizedURL.hasPrefix("https://") {
            normalizedURL = "https://\(normalizedURL)"
        }

        guard let url = URL(string: normalizedURL) else {
            throw AppError.invalidURL
        }

        let token = try await apiClient.login(
            serverURL: url,
            username: username,
            password: password
        )

        authState.setCredentials(token: token, serverURL: normalizedURL)
    }

    func ping() async throws -> Bool {
        let response: PingDTO = try await apiClient.request(endpoint: .ping)
        return response.response == "pong"
    }

    func fetchUserAccount() async throws {
        let dto: UserAccountDTO = try await apiClient.request(endpoint: .userAccount)
        authState.setPrivileges(
            isSuperuser: dto.isSuperuser ?? false,
            isStaff: dto.isStaff ?? false
        )
    }

    func logout() {
        authState.handleUnauthorized()
    }
}
