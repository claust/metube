import Foundation
import SwiftUI

/// Which channels the active profile subscribes to, and the one place that changes it.
///
/// Injected as an @EnvironmentObject so a card's menu can label itself Subscribe or Unsubscribe
/// without asking the network, and so every card for the same channel re-labels the moment one
/// of them is toggled.
///
/// The set is cached in UserDefaults per profile — like `WatchProgressStore`, and for the same
/// reason: it is not a secret, it is cheap to lose, and having it on hand at launch means the
/// first menu the user opens is already labelled correctly rather than after a round-trip.
/// The network remains the truth; `refresh` overwrites the cache with it.
@MainActor
final class SubscriptionStore: ObservableObject {

    @Published private(set) var channelIDs: Set<String> = []

    /// The same subscriptions with their names and pictures, in the order YouTube listed them,
    /// for the Subscriptions screen to draw. Not cached to disk, unlike the ids: it is a screen
    /// the user has to go looking for rather than a label on every card menu, so one request on
    /// arrival is cheap enough — and it spares the app a stored copy of every channel name that
    /// would go stale silently.
    @Published private(set) var channels: [SubscribedChannel] = []

    /// Channels with a subscribe/unsubscribe request in flight. The menu disables its toggle for
    /// these, so a double press can't fire the opposite call before the first one lands.
    @Published private(set) var pending: Set<String> = []

    private let defaults: UserDefaults
    /// Whose subscriptions are loaded, and `nil` when nobody is signed in.
    private var profileID: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Profiles

    /// Points the store at a profile's subscriptions, replacing whatever was loaded. Pass `nil`
    /// when the last profile signs out.
    func activate(profileID: String?) {
        guard profileID != self.profileID else { return }
        self.profileID = profileID
        pending = []
        channelIDs = profileID.map(load(profileID:)) ?? []
        // Nothing of the list survives a profile switch: it isn't cached, and showing the
        // previous account's channels while the new one's load is in flight would be a lie the
        // screen has no way to mark as one.
        channels = []
    }

    func isSubscribed(_ channelID: String) -> Bool { channelIDs.contains(channelID) }

    func isPending(_ channelID: String) -> Bool { pending.contains(channelID) }

    // MARK: - Reading

    /// Replaces the cached set with what the account actually subscribes to. Called as the feed
    /// loads; failures are silent because a stale label on a menu nobody has opened yet is not
    /// worth an error banner over the feed.
    func refresh(using authStore: AuthStore) async {
        try? await reload(using: authStore)
    }

    /// The same load, for the Subscriptions screen — which, unlike the card menus, is *about*
    /// this list and so has both a spinner and an error state to put a failure in.
    ///
    /// Returns whether the list was replaced: `false` means the request was cancelled or nobody
    /// is signed in, neither of which is an empty subscription list.
    @discardableResult
    func reload(using authStore: AuthStore) async throws -> Bool {
        guard profileID != nil else { return false }
        let loaded = try await authStore.authorized { token in
            try await SubscriptionService().loadSubscriptions(accessToken: token)
        }
        // `authorized` returns nil for "cancelled or signed out", which is not an empty
        // subscription list — writing that through would wipe the cache for no reason.
        guard let listing = loaded else { return false }
        channelIDs = listing.channelIDs
        channels = listing.channels
        persist()
        return true
    }

    /// Records a subscription state we learned from somewhere other than the subscription list —
    /// the channel screen's own subscribe button, which reports it per channel.
    func note(_ subscribed: Bool, for channelID: String) {
        // A press already on its way is more current than a page that was loaded before it.
        guard !pending.contains(channelID) else { return }
        guard apply(subscribed, to: channelID) else { return }
        persist()
    }

    // MARK: - Writing

    /// Subscribes or unsubscribes, flipping the local state first so the menu closes onto the
    /// new label immediately, and putting it back if the request fails.
    func setSubscribed(_ subscribed: Bool, channelID: String, using authStore: AuthStore) async {
        guard !pending.contains(channelID) else { return }
        guard apply(subscribed, to: channelID) else { return }
        persist()

        pending.insert(channelID)
        defer { pending.remove(channelID) }

        let service = SubscriptionService()
        do {
            let result = try await authStore.authorized { token in
                if subscribed {
                    try await service.subscribe(channelID: channelID, accessToken: token)
                } else {
                    try await service.unsubscribe(channelID: channelID, accessToken: token)
                }
            }
            // nil is "cancelled or signed out". A sign-out has already emptied this store via
            // `activate`, so there is nothing to roll back to.
            guard result != nil else { return }
        } catch {
            if isCancellation(error) { return }
            _ = apply(!subscribed, to: channelID)
            persist()
        }
    }

    /// Applies a state to the set, returning whether it actually changed anything — a no-op
    /// toggle shouldn't cost a write or a redraw.
    private func apply(_ subscribed: Bool, to channelID: String) -> Bool {
        if subscribed {
            return channelIDs.insert(channelID).inserted
        }
        // Take it off the Subscriptions screen too, so unsubscribing from a channel's own page
        // and pressing back doesn't land on a list still showing it. The reverse has no
        // equivalent: subscribing tells us an id and nothing else, and a tile with no name or
        // picture is worse than one that appears on the next load.
        channels.removeAll { $0.id == channelID }
        return channelIDs.remove(channelID) != nil
    }

    // MARK: - Storage

    private static func storageKey(profileID: String) -> String { "yt.subscriptions.\(profileID)" }

    private func load(profileID: String) -> Set<String> {
        Set(defaults.stringArray(forKey: Self.storageKey(profileID: profileID)) ?? [])
    }

    /// Written inline rather than off the actor, unlike watch progress: this is a few hundred
    /// short strings at most, and it changes on a menu press rather than every few seconds of
    /// playback.
    private func persist() {
        guard let profileID else { return }
        defaults.set(Array(channelIDs).sorted(), forKey: Self.storageKey(profileID: profileID))
    }
}
