import Foundation
import SwiftUI

/// Holds the OAuth tokens and login state. Injected as an @EnvironmentObject.
/// Tokens are persisted in the Keychain (not UserDefaults) so login survives relaunch
/// without keeping long-lived credentials in plaintext preferences.
@MainActor
final class AuthStore: ObservableObject {
    @Published private(set) var accessToken: String?
    @Published private(set) var refreshToken: String?

    private let accessKey = "yt.accessToken"
    private let refreshKey = "yt.refreshToken"

    var isLoggedIn: Bool { accessToken != nil }

    init() {
        accessToken = KeychainStore.get(accessKey)
        refreshToken = KeychainStore.get(refreshKey)
    }

    func setTokens(access: String, refresh: String?) {
        accessToken = access
        KeychainStore.set(access, for: accessKey)
        // A refresh response may omit refresh_token; keep the existing one when so (per OAuth).
        if let refresh {
            refreshToken = refresh
            KeychainStore.set(refresh, for: refreshKey)
        }
    }

    /// Update only the access token (e.g. after a refresh) keeping the refresh token.
    func updateAccessToken(_ access: String) {
        accessToken = access
        KeychainStore.set(access, for: accessKey)
    }

    func logout() {
        accessToken = nil
        refreshToken = nil
        KeychainStore.delete(accessKey)
        KeychainStore.delete(refreshKey)
    }
}
