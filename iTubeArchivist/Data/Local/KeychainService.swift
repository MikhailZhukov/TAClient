import Foundation
import Security

final class KeychainService {
    private let serviceName = "ru.mzhukov.iTubeArchivist"
    private let accessGroup = "5AS4WKH94K.ru.mzhukov.iTubeArchivist"

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

    func migrateToSharedAccessGroup() {
        for key in [Key.authToken, Key.serverURL] {
            // Check if value already exists in shared group
            if load(for: key) != nil { continue }

            // Try to read from old query (no access group)
            let oldQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: key.rawValue,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]

            var result: AnyObject?
            let status = SecItemCopyMatching(oldQuery as CFDictionary, &result)

            guard status == errSecSuccess, let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                continue
            }

            // Save to shared group
            save(value, for: key)

            // Delete old entry (without access group)
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: key.rawValue,
            ]
            SecItemDelete(deleteQuery as CFDictionary)
        }
    }
}
