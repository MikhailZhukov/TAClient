import Foundation
import Security

final class KeychainService {
    private let serviceName = "ru.mzhukov.TAClient"
    private let accessGroup = "5AS4WKH94K.ru.mzhukov.TAClient"

    enum Key: String {
        case authToken = "auth_token"
        case serverURL = "server_url"
    }

    private func baseQuery(for key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }

    func save(_ value: String, for key: Key) {
        let data = Data(value.utf8)
        let query = baseQuery(for: key)

        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    func load(for key: Key) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func delete(for key: Key) {
        let query = baseQuery(for: key)
        SecItemDelete(query as CFDictionary)
    }

    func clearAll() {
        delete(for: .authToken)
        delete(for: .serverURL)
    }
}
