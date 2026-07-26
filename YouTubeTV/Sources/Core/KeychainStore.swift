import Foundation
import Security

/// Minimal Keychain wrapper for storing small secrets (OAuth tokens) as generic passwords.
/// Used instead of UserDefaults so credentials aren't kept in plaintext preferences.
enum KeychainStore {
    /// All items are scoped under this service so they're easy to enumerate/remove.
    private static let service = "dk.delectosoft.metube.tokens"

    static func set(_ value: String?, for account: String) {
        // A nil value clears the item.
        guard let value, let data = value.data(using: .utf8) else {
            delete(account)
            return
        }
        // Identity of the item (without the value/accessibility attributes).
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Try to add; if it already exists, update in place. This is atomic — a failed write
        // never erases the existing credential (unlike delete-then-add).
        var addQuery = base
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

        if addStatus == errSecDuplicateItem {
            let attributes: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
            log(updateStatus, op: "update", account: account)
        } else {
            log(addStatus, op: "add", account: account)
        }
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
