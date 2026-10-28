import Foundation
import Security

/// Internet passwords in the login Keychain. Never written to JSON, UserDefaults, or logs.
enum PasswordVault {
    struct Account: Equatable, Identifiable {
        var host: String
        var username: String
        var id: String { host + "\n" + username }
    }

    static func accounts(for host: String) -> [Account] {
        allAccounts().filter { $0.host.caseInsensitiveCompare(host) == .orderedSame }
    }

    static func allAccounts() -> [Account] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrLabel as String: labelPrefix,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let rows = item as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let host = row[kSecAttrServer as String] as? String,
                  let username = row[kSecAttrAccount as String] as? String else { return nil }
            return Account(host: host, username: username)
        }.sorted { $0.host < $1.host }
    }

    /// Caller must not log, store, or publish the returned string.
    static func password(host: String, username: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: username,
            kSecAttrLabel as String: labelPrefix,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(host: String, username: String, password: String) -> Bool {
        let account = username.isEmpty ? "unknown" : username
        if save(host: host, username: account, password: password, synchronizable: true) {
            return true
        }
        return save(host: host, username: account, password: password, synchronizable: false)
    }

    static func delete(host: String, username: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: username,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static let labelPrefix = "Sathariels Browser"

    private static func save(host: String, username: String, password: String, synchronizable: Bool) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }
        let base: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: username,
            kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
            kSecAttrPort as String: 443,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue as Any : kCFBooleanFalse as Any
        ]
        SecItemDelete(base as CFDictionary)
        var insert = base
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        insert[kSecAttrLabel as String] = labelPrefix
        let status = SecItemAdd(insert as CFDictionary, nil)
        return status == errSecSuccess
    }
}
