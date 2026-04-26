import Foundation
import Testing
@testable import TAClient

struct UserAccountDTOTests {

    @Test func jsonDecoding_fullResponse() throws {
        let json = """
        {
            "id": 1,
            "name": "admin",
            "is_superuser": true,
            "is_staff": true
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(UserAccountDTO.self, from: json)
        #expect(dto.id == 1)
        #expect(dto.name == "admin")
        #expect(dto.isSuperuser == true)
        #expect(dto.isStaff == true)
    }

    @Test func jsonDecoding_regularUser() throws {
        let json = """
        {
            "id": 2,
            "name": "viewer",
            "is_superuser": false,
            "is_staff": false
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(UserAccountDTO.self, from: json)
        #expect(dto.isSuperuser == false)
        #expect(dto.isStaff == false)
    }

    @Test func jsonDecoding_missingFields() throws {
        let json = """
        { "id": 1 }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(UserAccountDTO.self, from: json)
        #expect(dto.isSuperuser == nil)
        #expect(dto.isStaff == nil)
        #expect(dto.name == nil)
    }
}

struct AuthStatePrivilegeTests {

    @Test func isPrivileged_superuser() {
        let keychain = KeychainService()
        keychain.clearAll()
        let state = AuthState(keychainService: keychain)

        state.setPrivileges(isSuperuser: true, isStaff: false)
        #expect(state.isPrivileged == true)
    }

    @Test func isPrivileged_staff() {
        let keychain = KeychainService()
        keychain.clearAll()
        let state = AuthState(keychainService: keychain)

        state.setPrivileges(isSuperuser: false, isStaff: true)
        #expect(state.isPrivileged == true)
    }

    @Test func isPrivileged_both() {
        let keychain = KeychainService()
        keychain.clearAll()
        let state = AuthState(keychainService: keychain)

        state.setPrivileges(isSuperuser: true, isStaff: true)
        #expect(state.isPrivileged == true)
    }

    @Test func isPrivileged_neither() {
        let keychain = KeychainService()
        keychain.clearAll()
        let state = AuthState(keychainService: keychain)

        state.setPrivileges(isSuperuser: false, isStaff: false)
        #expect(state.isPrivileged == false)
    }

    @Test func isPrivileged_defaultsFalse() {
        let keychain = KeychainService()
        keychain.clearAll()
        let state = AuthState(keychainService: keychain)

        #expect(state.isPrivileged == false)
    }

    @Test func handleUnauthorized_clearsPrivileges() {
        let keychain = KeychainService()
        keychain.clearAll()
        let state = AuthState(keychainService: keychain)
        state.setCredentials(token: "tok", serverURL: "https://example.com")
        state.setPrivileges(isSuperuser: true, isStaff: true)

        state.handleUnauthorized()

        #expect(state.isPrivileged == false)
        #expect(state.isSuperuser == false)
        #expect(state.isStaff == false)
    }
}

struct UserAccountEndpointTests {

    @Test func endpoint_path() {
        let endpoint = APIEndpoint.userAccount
        #expect(endpoint.path.contains("/api/user/account"))
    }

    @Test func endpoint_method_isGet() {
        let endpoint = APIEndpoint.userAccount
        #expect(endpoint.method == .get)
    }
}

extension DataLayerSuite {
@Suite(.serialized) struct AuthRepositoryUserAccountTests {

    init() {
        MockResponse.tearDown()
    }

    @Test func fetchUserAccount_superuser_setsPrivileges() async throws {
        let (client, authState) = MockResponse.makeAPIClient()
        let repo = AuthRepositoryImpl(apiClient: client, authState: authState)

        MockResponse.setUp(json: [
            "id": 1,
            "name": "admin",
            "is_superuser": true,
            "is_staff": true,
        ] as [String: Any])

        try await repo.fetchUserAccount()

        #expect(authState.isSuperuser == true)
        #expect(authState.isStaff == true)
        #expect(authState.isPrivileged == true)
        authState.handleUnauthorized()
    }

    @Test func fetchUserAccount_regularUser_notPrivileged() async throws {
        let (client, authState) = MockResponse.makeAPIClient()
        let repo = AuthRepositoryImpl(apiClient: client, authState: authState)

        MockResponse.setUp(json: [
            "id": 2,
            "name": "viewer",
            "is_superuser": false,
            "is_staff": false,
        ] as [String: Any])

        try await repo.fetchUserAccount()

        #expect(authState.isPrivileged == false)
        authState.handleUnauthorized()
    }

    @Test func fetchUserAccount_missingFields_defaultsFalse() async throws {
        let (client, authState) = MockResponse.makeAPIClient()
        let repo = AuthRepositoryImpl(apiClient: client, authState: authState)

        MockResponse.setUp(json: ["id": 1] as [String: Any])

        try await repo.fetchUserAccount()

        #expect(authState.isPrivileged == false)
        authState.handleUnauthorized()
    }
}
}
