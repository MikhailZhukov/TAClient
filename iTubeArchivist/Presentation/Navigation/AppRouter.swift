import SwiftUI

enum AppState {
    case splash
    case login
    case authenticated
}

@Observable
final class AppRouter {
    var path = NavigationPath()
    var appState: AppState

    private let authState: AuthState

    init(authState: AuthState) {
        self.authState = authState
        self.appState = authState.isAuthenticated ? .splash : .login
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
        appState = .login
    }

    func onLoginSuccess() {
        path = NavigationPath()
        appState = .authenticated
    }

    func onAutoLoginFailed() {
        authState.handleUnauthorized()
        appState = .login
    }
}
