import Foundation

@Observable
final class LoginViewModel {
    var serverURL: String = ""
    var username: String = ""
    var password: String = ""
    var isLoading: Bool = false
    var errorMessage: String?
    var isAutoLoginInProgress: Bool = false

    private let authRepository: AuthRepositoryProtocol
    private let authState: AuthState
    private let router: AppRouter

    init(authRepository: AuthRepositoryProtocol, authState: AuthState, router: AppRouter) {
        self.authRepository = authRepository
        self.authState = authState
        self.router = router
    }

    func attemptAutoLogin() async {
        guard authState.isAuthenticated else { return }
        isAutoLoginInProgress = true
        do {
            let isValid = try await authRepository.ping()
            if isValid {
                router.onLoginSuccess()
            } else {
                authState.handleUnauthorized()
            }
        } catch is AppError {
            authState.handleUnauthorized()
        } catch {
            authState.handleUnauthorized()
        }
        isAutoLoginInProgress = false
    }

    func login() async {
        guard !serverURL.isEmpty, !username.isEmpty, !password.isEmpty else {
            errorMessage = String(localized: "login_error_fields_required")
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            try await authRepository.login(
                serverURL: serverURL,
                username: username,
                password: password
            )
            router.onLoginSuccess()
        } catch let error as AppError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = String(localized: "error_generic")
        }

        isLoading = false
    }
}
