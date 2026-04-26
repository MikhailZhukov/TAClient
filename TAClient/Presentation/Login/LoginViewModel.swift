import Foundation

@Observable
final class LoginViewModel {
    var serverURL: String = ""
    var username: String = ""
    var password: String = ""
    var isLoading: Bool = false
    var errorMessage: String?

    private let authRepository: AuthRepositoryProtocol
    private let router: AppRouter

    init(authRepository: AuthRepositoryProtocol, router: AppRouter) {
        self.authRepository = authRepository
        self.router = router
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
            try? await authRepository.fetchUserAccount()
            router.onLoginSuccess()
        } catch {
            router.handleError(error, errorMessage: &errorMessage)
        }

        isLoading = false
    }
}
