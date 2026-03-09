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
    private(set) var watchedChanges: [String: Bool] = [:]

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

    func markWatchedChanged(_ videoId: String, isWatched: Bool) {
        watchedChanges[videoId] = isWatched
    }

    func handleUnauthorized() {
        authState.handleUnauthorized()
        path = NavigationPath()
        deletedVideoIds.removeAll()
        watchedChanges.removeAll()
        appState = .login
    }

    func onLoginSuccess() {
        path = NavigationPath()
        deletedVideoIds.removeAll()
        watchedChanges.removeAll()
        appState = .authenticated
    }

    func onAutoLoginFailed() {
        authState.handleUnauthorized()
        appState = .login
    }

    /// Handles errors from async repository calls.
    /// Returns `true` if the error was unauthorized (caller should stop further work).
    @discardableResult
    func handleError(_ error: Error, errorMessage: inout String?) -> Bool {
        if let appError = error as? AppError, case .unauthorized = appError {
            handleUnauthorized()
            return true
        }
        if let appError = error as? AppError {
            errorMessage = appError.errorDescription
        } else {
            errorMessage = String(localized: "error_generic")
        }
        return false
    }
}
