import Foundation

@Observable
final class AuthState {
    private(set) var token: String?
    private(set) var serverURL: String?
    private(set) var isSuperuser = false
    private(set) var isStaff = false
    private let keychainService: KeychainService

    var isAuthenticated: Bool {
        token != nil && serverURL != nil
    }

    var isPrivileged: Bool {
        isSuperuser || isStaff
    }

    var baseURL: URL? {
        guard let serverURL else { return nil }
        return URL(string: serverURL)
    }

    init(keychainService: KeychainService) {
        self.keychainService = keychainService
        self.token = keychainService.load(for: .authToken)
        self.serverURL = keychainService.load(for: .serverURL)
    }

    func setCredentials(token: String, serverURL: String) {
        self.token = token
        self.serverURL = serverURL
        keychainService.save(token, for: .authToken)
        keychainService.save(serverURL, for: .serverURL)
    }

    func setPrivileges(isSuperuser: Bool, isStaff: Bool) {
        self.isSuperuser = isSuperuser
        self.isStaff = isStaff
    }

    func handleUnauthorized() {
        token = nil
        serverURL = nil
        isSuperuser = false
        isStaff = false
        keychainService.clearAll()
    }
}
