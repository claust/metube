import Foundation
import SwiftUI

/// Holds the OAuth tokens and login state. Injected as an @EnvironmentObject.
/// Persists tokens in UserDefaults so login survives app relaunch.
@MainActor
final class AuthStore: ObservableObject {
    @Published private(set) var accessToken: String?
    @Published private(set) var refreshToken: String?

    private let accessKey = "yt.accessToken"
    private let refreshKey = "yt.refreshToken"

    var isLoggedIn: Bool { accessToken != nil }

    init() {
        accessToken = UserDefaults.standard.string(forKey: accessKey)
        refreshToken = UserDefaults.standard.string(forKey: refreshKey)
    }

    func setTokens(access: String, refresh: String?) {
        accessToken = access
        UserDefaults.standard.set(access, forKey: accessKey)
        if let refresh {
            refreshToken = refresh
            UserDefaults.standard.set(refresh, forKey: refreshKey)
        }
    }

    /// Update only the access token (e.g. after a refresh) keeping the refresh token.
    func updateAccessToken(_ access: String) {
        accessToken = access
        UserDefaults.standard.set(access, forKey: accessKey)
    }

    func logout() {
        accessToken = nil
        refreshToken = nil
        UserDefaults.standard.removeObject(forKey: accessKey)
        UserDefaults.standard.removeObject(forKey: refreshKey)
    }
}
