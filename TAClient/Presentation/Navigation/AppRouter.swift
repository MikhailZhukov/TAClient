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
    private(set) var deletedVideoIds: Set<String> = []

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

    func markVideoDeleted(_ videoId: String) {
        deletedVideoIds.insert(videoId)
    }

    func handleUnauthorized() {
        authState.handleUnauthorized()
        path = NavigationPath()
        deletedVideoIds.removeAll()
        appState = .login
    }

    func onLoginSuccess() {
        path = NavigationPath()
        deletedVideoIds.removeAll()
        appState = .authenticated
    }

    func onAutoLoginFailed() {
        authState.handleUnauthorized()
        appState = .login
    }
}
