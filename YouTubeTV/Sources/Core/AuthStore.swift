import Foundation
import SwiftUI

/// Holds every signed-in profile, which one is active, and their OAuth tokens.
/// Injected as an @EnvironmentObject.
///
/// Tokens are persisted in the Keychain (not UserDefaults) so logins survive relaunch without
/// keeping long-lived credentials in plaintext preferences; the profile list itself carries no
/// secrets and is plain JSON alongside the rest of the app's preferences.
@MainActor
final class AuthStore: ObservableObject {
    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var activeProfileID: String?
    /// The active profile's access token. Published rather than computed so a view reloads its
    /// feed when the profile changes, not just when the token does.
    @Published private(set) var accessToken: String?

    /// Tokens for every profile, not just the active one — switching profiles has to be
    /// instant, and re-reading the Keychain on each switch would make it a disk round-trip.
    private var accessTokens: [String: String] = [:]
    private var refreshTokens: [String: String] = [:]

    private let defaults: UserDefaults
    private let profilesKey = "yt.profiles"
    private let activeProfileKey = "yt.activeProfile"

    var isLoggedIn: Bool { accessToken != nil }
    var activeProfile: Profile? { profiles.first { $0.id == activeProfileID } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        profiles = Self.decodeProfiles(defaults.data(forKey: profilesKey))
        let migrated = profiles.isEmpty && adoptLegacySingleProfile()
        loadTokens()

        // A profile whose Keychain entry has gone (restored backup, Keychain reset) can't be
        // signed in as, and an avatar that fails on every press is worse than no avatar.
        let usable = profiles.filter { accessTokens[$0.id] != nil }
        let pruned = usable.count != profiles.count
        profiles = usable

        let stored = defaults.string(forKey: activeProfileKey)
        activeProfileID = profiles.contains(where: { $0.id == stored }) ? stored : profiles.first?.id
        accessToken = activeProfileID.flatMap { accessTokens[$0] }

        if migrated || pruned { saveProfiles() }
    }

    // MARK: - Sign in / out

    /// Adds the account the tokens belong to and switches to it. Signing into an account that
    /// is already in the bar refreshes it in place rather than adding a second avatar for it.
    func signIn(tokens: DeviceAuthService.Tokens) async {
        let info = try? await AccountService().loadAccount(accessToken: tokens.accessToken)
        let existing = info.flatMap { info in profiles.first { $0.accountKey == info.key } }

        var profile =
            existing
            ?? Profile(
                id: Profile.id(for: info?.key), accountKey: info?.key, displayName: "", avatarURL: nil)
        if let info {
            profile.accountKey = info.key
            profile.displayName = info.name
            profile.avatarURL = info.avatarURL
        }

        store(tokens: tokens, for: profile.id)
        upsert(profile)
        activate(profile.id)
    }

    func activate(_ profileID: String) {
        guard profiles.contains(where: { $0.id == profileID }) else { return }
        activeProfileID = profileID
        accessToken = accessTokens[profileID]
        defaults.set(profileID, forKey: activeProfileKey)
    }

    /// Removes the profile at the user's request, along with everything it owns on this device.
    /// Its watch progress goes too: signing a profile out of a shared TV should leave nothing of
    /// it behind.
    func signOut(_ profileID: String) {
        WatchProgressStore.discardEntries(profileID: profileID, defaults: defaults)
        invalidate(profileID)
    }

    /// Drops a profile whose credentials no longer work, keeping its watch progress: the user
    /// didn't ask to be forgotten, and because the id is derived from the account, signing back
    /// in restores the history rather than starting over.
    private func invalidate(_ profileID: String) {
        profiles.removeAll { $0.id == profileID }
        accessTokens[profileID] = nil
        refreshTokens[profileID] = nil
        KeychainStore.delete(accessKey(profileID))
        KeychainStore.delete(refreshKey(profileID))
        saveProfiles()

        guard profileID == activeProfileID else { return }
        // Fall through to whoever is left, so removing one of several profiles doesn't drop the
        // whole TV back to the sign-in screen.
        if let next = profiles.first {
            activate(next.id)
        } else {
            activeProfileID = nil
            accessToken = nil
            defaults.removeObject(forKey: activeProfileKey)
        }
    }

    // MARK: - Tokens

    /// Attempt to obtain a fresh access token for a profile using its stored refresh token.
    /// Returns true on success. On failure the profile is dropped (see `invalidate`) so the UI
    /// moves on rather than getting stuck in a broken "signed in" state.
    @discardableResult
    func refresh(profileID: String? = nil) async -> Bool {
        guard let profileID = profileID ?? activeProfileID else { return false }
        guard await renewTokens(for: profileID) else {
            invalidate(profileID)
            return false
        }
        return true
    }

    /// The token exchange on its own, leaving a profile that fails it in place. Used where the
    /// refresh is incidental — filling in an avatar is not worth signing someone out over, and
    /// a transient failure there would take the profile with it.
    private func renewTokens(for profileID: String) async -> Bool {
        guard let refreshToken = refreshTokens[profileID] else { return false }
        guard let tokens = try? await DeviceAuthService().refreshTokens(refreshToken: refreshToken)
        else { return false }
        store(tokens: tokens, for: profileID)
        return true
    }

    private func store(tokens: DeviceAuthService.Tokens, for profileID: String) {
        accessTokens[profileID] = tokens.accessToken
        KeychainStore.set(tokens.accessToken, for: accessKey(profileID))
        // A refresh response may omit refresh_token; keep the existing one when so (per OAuth).
        if let refresh = tokens.refreshToken {
            refreshTokens[profileID] = refresh
            KeychainStore.set(refresh, for: refreshKey(profileID))
        }
        if profileID == activeProfileID { accessToken = tokens.accessToken }
    }

    private func loadTokens() {
        for profile in profiles {
            accessTokens[profile.id] = KeychainStore.get(accessKey(profile.id))
            refreshTokens[profile.id] = KeychainStore.get(refreshKey(profile.id))
        }
    }

    private func accessKey(_ profileID: String) -> String { "yt.\(profileID).accessToken" }
    private func refreshKey(_ profileID: String) -> String { "yt.\(profileID).refreshToken" }

    // MARK: - Account details

    /// Fills in the name and avatar of any profile that doesn't have them yet — a profile
    /// carried over from the single-account build, or one added while the account lookup was
    /// unreachable. Runs once per launch; a profile that already has its details costs nothing.
    func backfillAccountInfo() async {
        for profile in profiles where profile.accountKey == nil {
            guard let token = accessTokens[profile.id] else { continue }
            var info = try? await AccountService().loadAccount(accessToken: token)
            // An expired access token is the likeliest reason this failed, and it would fail
            // again on every launch until something else happened to refresh it.
            if info == nil, await renewTokens(for: profile.id), let retryToken = accessTokens[profile.id] {
                info = try? await AccountService().loadAccount(accessToken: retryToken)
            }
            // Re-read the profile rather than mutating the loop's copy: the refresh above, or a
            // sign-out while this was in flight, may have moved on without it.
            guard let info, var updated = profiles.first(where: { $0.id == profile.id }) else { continue }
            updated.accountKey = info.key
            updated.displayName = info.name
            updated.avatarURL = info.avatarURL
            upsert(updated)
        }
    }

    // MARK: - Persistence

    private func upsert(_ profile: Profile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        saveProfiles()
    }

    private func saveProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: profilesKey)
    }

    private static func decodeProfiles(_ data: Data?) -> [Profile] {
        guard let data, let decoded = try? JSONDecoder().decode([Profile].self, from: data) else {
            return []
        }
        return decoded
    }

    /// Carries the single login of the pre-profiles build over as the first profile, taking its
    /// watch history with it. Returns whether anything was found to migrate.
    private func adoptLegacySingleProfile() -> Bool {
        let legacyAccessKey = "yt.accessToken"
        let legacyRefreshKey = "yt.refreshToken"
        guard let access = KeychainStore.get(legacyAccessKey) else { return false }

        // No account details yet — `backfillAccountInfo` fetches them on this same launch, and
        // until then the bar shows the placeholder avatar.
        let profile = Profile(id: UUID().uuidString, accountKey: nil, displayName: "", avatarURL: nil)
        KeychainStore.set(access, for: accessKey(profile.id))
        if let refresh = KeychainStore.get(legacyRefreshKey) {
            KeychainStore.set(refresh, for: refreshKey(profile.id))
        }
        KeychainStore.delete(legacyAccessKey)
        KeychainStore.delete(legacyRefreshKey)
        WatchProgressStore.adoptLegacyEntries(profileID: profile.id, defaults: defaults)

        profiles = [profile]
        return true
    }
}
