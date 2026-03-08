import Foundation

protocol AuthRepositoryProtocol {
    func login(serverURL: String, username: String, password: String) async throws
    func ping() async throws -> Bool
    func logout()
}
