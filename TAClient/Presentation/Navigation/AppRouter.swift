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
    private var didHandleUnauth: Bool = false
    @ObservationIgnored private var unauthorizedObserver: NSObjectProtocol?

    init(authState: AuthState) {
        self.authState = authState
        self.appState = authState.isAuthenticated ? .splash : .login

        // Subscribe to Data-layer auth failure notifications. The preloader and
        // `CachingResourceLoader` don't go through `APIClient`, so they post
        // this instead of propagating a typed `AppError.unauthorized` upward.
        self.unauthorizedObserver = NotificationCenter.default.addObserver(
            forName: .taAuthUnauthorized,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleUnauthorized()
        }
    }

    deinit {
        if let token = unauthorizedObserver {
            NotificationCenter.default.removeObserver(token)
        }
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
        // Idempotent: multiple concurrent data-layer failures (preloader,
        // resource loader, API) often fire this in rapid succession. We only
        // want to wipe state and transition to `.login` once per session.
        if didHandleUnauth { return }
        didHandleUnauth = true

        authState.handleUnauthorized()
        path = NavigationPath()
        deletedVideoIds.removeAll()
        watchedChanges.removeAll()
        appState = .login
    }

    func onLoginSuccess() {
        didHandleUnauth = false
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
