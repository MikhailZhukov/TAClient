import SwiftUI
import OSLog

private let logger = Logger(subsystem: "ru.mzhukov.TAClient", category: "AppRouter")

enum AppState {
    case splash
    case login
    case authenticated
    case unavailable
}

@Observable
final class AppRouter {
    var path = NavigationPath()
    var appState: AppState
    private(set) var deletedVideoIds: Set<String> = []
    private(set) var watchedChanges: [String: Bool] = [:]

    private let authState: AuthState
    private let authRepository: AuthRepositoryProtocol
    private var didHandleUnauth: Bool = false
    @ObservationIgnored private var unauthorizedObserver: NSObjectProtocol?

    init(authState: AuthState, authRepository: AuthRepositoryProtocol) {
        self.authState = authState
        self.authRepository = authRepository
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

    /// Server is unreachable (offline, restart, 5xx) — keep credentials
    /// intact and offer the reconnect screen instead of wiping the session.
    func onStartupUnavailable() {
        appState = .unavailable
    }

    /// Startup sequence, idempotent: safe to call from the `.splash` task and
    /// from ReconnectView's Retry button. Only `AppError.unauthorized` wipes
    /// the session; every other ping failure shows `.unavailable`.
    func attemptStartup() async {
        do {
            let isValid = try await authRepository.ping()
            guard isValid else {
                onStartupUnavailable()
                return
            }
        } catch {
            switch StartupOutcome.classify(error) {
            case .unauthorized:
                handleUnauthorized()
            case .unavailable:
                onStartupUnavailable()
            }
            return
        }

        do {
            try await authRepository.fetchUserAccount()
        } catch {
            if case AppError.unauthorized = error {
                handleUnauthorized()
                return
            }
            // Server is alive but account fetch failed — preserve the previous
            // `try?` behavior: continue with reduced privileges (isPrivileged false).
            logger.error("fetchUserAccount failed after successful ping: \(error). Continuing with reduced privileges.")
        }
        onLoginSuccess()
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
