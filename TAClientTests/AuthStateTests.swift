import Foundation
import Testing
@testable import TAClient

struct AuthStateTests {

    private func makeAuthState() -> AuthState {
        let keychain = KeychainService()
        keychain.clearAll()
        return AuthState(keychainService: keychain)
    }

    @Test func isAuthenticated_whenBothPresent_returnsTrue() {
        let authState = makeAuthState()
        authState.setCredentials(token: "tok", serverURL: "https://ta.example.com")
        #expect(authState.isAuthenticated == true)
    }

    @Test func isAuthenticated_whenTokenNil_returnsFalse() {
        let authState = makeAuthState()
        #expect(authState.isAuthenticated == false)
    }

    @Test func setCredentials_updatesInMemoryState() {
        let authState = makeAuthState()
        #expect(authState.isAuthenticated == false)

        authState.setCredentials(token: "my-token", serverURL: "https://ta.example.com")

        #expect(authState.token == "my-token")
        #expect(authState.serverURL == "https://ta.example.com")
        #expect(authState.isAuthenticated == true)

        // Cleanup
        authState.handleUnauthorized()
    }

    @Test func handleUnauthorized_clearsEverything() {
        let authState = makeAuthState()
        authState.setCredentials(token: "tok", serverURL: "https://ta.example.com")
        #expect(authState.isAuthenticated == true)

        authState.handleUnauthorized()

        #expect(authState.token == nil)
        #expect(authState.serverURL == nil)
        #expect(authState.isAuthenticated == false)
    }

    @Test func baseURL_computesFromServerURL() {
        let authState = makeAuthState()
        #expect(authState.baseURL == nil)

        authState.setCredentials(token: "tok", serverURL: "https://ta.example.com")
        #expect(authState.baseURL == URL(string: "https://ta.example.com"))

        // Cleanup
        authState.handleUnauthorized()
    }
}
