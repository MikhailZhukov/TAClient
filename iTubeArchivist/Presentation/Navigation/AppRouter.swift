import SwiftUI

@Observable
final class AppRouter {
    var path = NavigationPath()
    var showLogin = false

    private let authState: AuthState

    init(authState: AuthState) {
        self.authState = authState
        self.showLogin = !authState.isAuthenticated
    }

    func navigate(to route: Route) {
        path.append(route)
    }

    func goBack() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    func handleUnauthorized() {
        authState.handleUnauthorized()
        path = NavigationPath()
        showLogin = true
    }

    func onLoginSuccess() {
        showLogin = false
        path = NavigationPath()
    }
}
