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
            kSecAttrAccount as String: account,
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

    /// What a read found. A lookup can fail without saying anything about whether the item is
    /// there — the keybag not being ready yet, an entitlement upset by an app update — and a
    /// caller that treats a nil as absence would act on a credential that hasn't gone anywhere.
    enum Lookup: Equatable {
        case found(String)
        /// The Keychain answered, and there is no such item.
        case missing
        /// The lookup itself failed. Whether the item exists is unknown.
        case failed(OSStatus)
    }

    static func lookup(_ account: String) -> Lookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            // Everything here is written as UTF-8 by `set`, so an item that won't decode is a
            // corrupt value rather than a failed read: report it as absent, to be replaced.
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                return .missing
            }
            return .found(value)
        case errSecItemNotFound:
            return .missing
        default:
            log(status, op: "read", account: account)
            return .failed(status)
        }
    }

    /// The stored value, with "not there" and "couldn't tell" both coming back as nil. For
    /// callers the difference doesn't matter to; anything that *discards* something on a nil
    /// wants `lookup` instead.
    static func get(_ account: String) -> String? {
        guard case .found(let value) = lookup(account) else { return nil }
        return value
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
