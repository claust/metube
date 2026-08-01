import SwiftUI

@main
struct YouTubeTVApp: App {
    @StateObject private var authStore: AuthStore
    @StateObject private var watchProgress: WatchProgressStore
    @StateObject private var watchProgressSync: WatchProgressSync
    @StateObject private var channelAvatars = ChannelAvatarStore()
    @StateObject private var subscriptions = SubscriptionStore()

    /// Built here rather than with property initialisers because the two are connected: the
    /// profile store tells the progress store when a profile's history is migrated, moved or
    /// deleted, and that has to reach the same instance the views are reading.
    @MainActor
    init() {
        // `AsyncImage` fetches through `URLSession.shared`, so this is what keeps an avatar or
        // thumbnail off the network the second time a row scrolls past. The default cache is a
        // few hundred KB — a screenful of artwork evicts it — and the images are immutable and
        // served with long lifetimes, so a real one on disk pays off immediately.
        URLCache.shared = URLCache(
            memoryCapacity: 32 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024)

        let watchProgress = WatchProgressStore()
        _watchProgress = StateObject(wrappedValue: watchProgress)
        _authStore = StateObject(wrappedValue: AuthStore(watchProgress: watchProgress))
        // Wraps the same store: it is what the sync uploads from and merges into.
        _watchProgressSync = StateObject(wrappedValue: WatchProgressSync(store: watchProgress))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authStore)
                .environmentObject(watchProgress)
                .environmentObject(watchProgressSync)
                .environmentObject(channelAvatars)
                .environmentObject(subscriptions)
        }
    }
}
