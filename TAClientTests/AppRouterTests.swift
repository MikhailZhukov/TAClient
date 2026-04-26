import SwiftUI
import Testing
@testable import TAClient

struct AppRouterTests {

    private func makeRouter(authenticated: Bool = false) -> AppRouter {
        let keychain = KeychainService()
        keychain.clearAll()
        let authState = AuthState(keychainService: keychain)
        if authenticated {
            authState.setCredentials(token: "tok", serverURL: "https://ta.example.com")
        }
        return AppRouter(authState: authState)
    }

    @Test func init_authenticated_startsSplash() {
        let router = makeRouter(authenticated: true)
        #expect(router.appState == .splash)

        // Cleanup
        router.handleUnauthorized()
    }

    @Test func init_unauthenticated_startsLogin() {
        let router = makeRouter(authenticated: false)
        #expect(router.appState == .login)
    }

    @Test func navigate_appendsToPath() {
        let router = makeRouter()
        #expect(router.path.isEmpty)

        router.navigate(to: .search)
        #expect(router.path.count == 1)

        router.navigate(to: .videoDetail(videoId: "abc"))
        #expect(router.path.count == 2)
    }

    @Test func goBack_removesFromPath() {
        let router = makeRouter()
        router.navigate(to: .search)
        router.navigate(to: .videoDetail(videoId: "abc"))
        #expect(router.path.count == 2)

        router.goBack()
        #expect(router.path.count == 1)
    }

    @Test func goBack_whenEmpty_doesNotCrash() {
        let router = makeRouter()
        #expect(router.path.isEmpty)
        router.goBack()
        #expect(router.path.isEmpty)
    }

    @Test func handleUnauthorized_setsLoginAndClearsPath() {
        let router = makeRouter(authenticated: true)
        router.navigate(to: .search)
        router.navigate(to: .videoDetail(videoId: "abc"))

        router.handleUnauthorized()

        #expect(router.appState == .login)
        #expect(router.path.isEmpty)
    }

    @Test func onLoginSuccess_setsAuthenticatedAndClearsPath() {
        let router = makeRouter()
        router.navigate(to: .search)

        router.onLoginSuccess()

        #expect(router.appState == .authenticated)
        #expect(router.path.isEmpty)
    }
}
