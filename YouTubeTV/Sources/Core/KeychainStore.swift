import Foundation
import Security

/// Minimal Keychain wrapper for storing small secrets (OAuth tokens) as generic passwords.
/// Used instead of UserDefaults so credentials aren't kept in plaintext preferences.
enum KeychainStore {
    /// All items are scoped under this service so they're easy to enumerate/remove.
    private static let service = "com.prototype.youtubetv.tokens"

    static func set(_ value: String?, for account: String) {
        // Remove any existing item first so this behaves as an upsert.
        delete(account)
        guard let value, let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        log(status, op: "add", account: account)
    }

    /// Surface Keychain failures in debug builds; they'd otherwise be silent.
    private static func log(_ status: OSStatus, op: String, account: String) {
        #if DEBUG
        if status != errSecSuccess {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            print("[KeychainStore] \(op) for \(account) failed: \(message)")
        }
        #endif
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
