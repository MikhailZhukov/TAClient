import Foundation
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
        return AppRouter(authState: authState, authRepository: MockAuthRepository())
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

    // MARK: - attemptStartup (session resilience A)

    private func makeStartupRouter() -> (router: AppRouter, authState: AuthState, authRepo: MockAuthRepository) {
        let keychain = KeychainService()
        keychain.clearAll()
        let authState = AuthState(keychainService: keychain)
        authState.setCredentials(token: "tok", serverURL: "https://ta.example.com")
        let authRepo = MockAuthRepository()
        let router = AppRouter(authState: authState, authRepository: authRepo)
        return (router, authState, authRepo)
    }

    @Test func attemptStartup_pingOk_accountOk_authenticates() async {
        let (router, authState, authRepo) = makeStartupRouter()
        nonisolated(unsafe) var fetchCount = 0
        authRepo.fetchUserAccountHandler = {
            fetchCount += 1
        }

        await router.attemptStartup()

        #expect(router.appState == .authenticated)
        #expect(authState.token != nil)
        #expect(fetchCount == 1, "account fetch must run after a successful ping")
    }

    @Test func attemptStartup_pingUnauthorized_wipesAndShowsLogin() async {
        let (router, authState, authRepo) = makeStartupRouter()
        authRepo.pingHandler = { throw AppError.unauthorized }

        await router.attemptStartup()

        #expect(router.appState == .login)
        #expect(authState.token == nil)
    }

    @Test func attemptStartup_pingNetworkError_keepsTokenAndShowsUnavailable() async {
        let (router, authState, authRepo) = makeStartupRouter()
        authRepo.pingHandler = { throw AppError.network(underlying: URLError(.notConnectedToInternet)) }

        await router.attemptStartup()

        #expect(router.appState == .unavailable)
        #expect(authState.token != nil)
    }

    @Test func attemptStartup_accountUnauthorized_wipesAndShowsLogin() async {
        let (router, authState, authRepo) = makeStartupRouter()
        authRepo.fetchUserAccountHandler = { throw AppError.unauthorized }

        await router.attemptStartup()

        #expect(router.appState == .login)
        #expect(authState.token == nil)
    }

    @Test func attemptStartup_accountNetworkError_continuesUnprivileged() async {
        let (router, authState, authRepo) = makeStartupRouter()
        nonisolated(unsafe) var fetchCount = 0
        authRepo.fetchUserAccountHandler = {
            fetchCount += 1
            throw AppError.network(underlying: nil)
        }

        await router.attemptStartup()

        // Server is alive — session preserved, reduced privileges (old try? behavior).
        #expect(router.appState == .authenticated)
        #expect(authState.token != nil)
        #expect(authState.isPrivileged == false)
        #expect(fetchCount == 1, "the failed account fetch must still have been attempted")
    }

    @Test func attemptStartup_pingNotPong_showsUnavailable() async {
        let (router, authState, authRepo) = makeStartupRouter()
        authRepo.pingHandler = { false } // 200 but response != "pong"

        await router.attemptStartup()

        #expect(router.appState == .unavailable)
        #expect(authState.token != nil)
    }

    @Test func onStartupUnavailable_showsUnavailableAndKeepsCredentials() {
        let (router, authState, _) = makeStartupRouter()

        router.onStartupUnavailable()

        #expect(router.appState == .unavailable)
        #expect(authState.token != nil)
        #expect(authState.isAuthenticated)
    }

    // MARK: - 403 semantics (session resilience B)

    @Test func handleError_permissionDenied_showsBannerWithoutLogout() {
        let (router, authState, _) = makeStartupRouter()
        var errorMessage: String? = nil

        let handled = router.handleError(AppError.permissionDenied, errorMessage: &errorMessage)

        #expect(!handled, ".permissionDenied must NOT route through handleUnauthorized")
        #expect(router.appState == .splash, "app state untouched — no logout")
        #expect(authState.token != nil, "credentials preserved")
        #expect(authState.isAuthenticated)
        #expect(errorMessage != nil, "banner message must be set")
        #expect(errorMessage == AppError.permissionDenied.errorDescription)
    }

    @Test func handleError_unauthorized_stillLogsOut() {
        let (router, authState, _) = makeStartupRouter()
        var errorMessage: String? = nil

        let handled = router.handleError(AppError.unauthorized, errorMessage: &errorMessage)

        #expect(handled)
        #expect(router.appState == .login)
        #expect(authState.token == nil)
    }
}
