import CryptoKit
import Foundation

/// One signed-in YouTube account.
///
/// Deliberately holds no credentials: the OAuth tokens live in the Keychain keyed by `id`,
/// while this metadata — which is not secret — is JSON in UserDefaults. `id` also namespaces
/// the profile's watch progress, so everything a profile owns hangs off this one value.
struct Profile: Identifiable, Codable, Hashable {
    let id: String
    /// YouTube's own identity for the account (its handle, failing that the account name).
    /// Used to recognise an account that is already signed in, and `nil` until the account
    /// menu has been read once.
    var accountKey: String?
    /// The account name as YouTube renders it. Empty until the account menu has been read.
    var displayName: String
    var avatarURL: URL?

    /// Derives the storage id from YouTube's identity, so an account that is removed and later
    /// added back lands on its own watch history rather than starting a fresh namespace.
    /// An account we couldn't identify falls back to a random id, which simply never matches again.
    static func id(for accountKey: String?) -> String {
        guard let accountKey else { return UUID().uuidString }
        let digest = SHA256.hash(data: Data(accountKey.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// What to show while YouTube hasn't told us the account's name yet.
    var name: String { displayName.isEmpty ? "Profile" : displayName }

    /// The letter drawn in place of a missing avatar image.
    var initial: String {
        guard let first = name.first else { return "?" }
        return String(first).uppercased()
    }
}
