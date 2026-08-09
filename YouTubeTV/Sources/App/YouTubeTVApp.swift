import SwiftUI

@main
struct YouTubeTVApp: App {
    @StateObject private var authStore: AuthStore
    @StateObject private var watchProgress: WatchProgressStore
    @StateObject private var watchProgressSync: WatchProgressSync
    @StateObject private var channelAvatars = ChannelAvatarStore()
    @StateObject private var subscriptions = SubscriptionStore()
    @StateObject private var watchHistory: WatchHistoryStore

    /// Built here rather than with property initialisers because they are connected: the profile
    /// store tells the progress store — and the history store — when a profile is migrated, moved
    /// or deleted, and that has to reach the same instances the views are reading.
    @MainActor
    init() {
        // `RemoteImage` fetches through `URLSession.shared`, so this is what keeps an avatar or
        // thumbnail off the network on the next launch — its own memory cache covers this one.
        // The default cache is a few hundred KB — a screenful of artwork evicts it — and the
        // images are immutable and served with long lifetimes, so a real one on disk pays off
        // immediately.
        URLCache.shared = URLCache(
            memoryCapacity: 32 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024)

        let watchProgress = WatchProgressStore()
        _watchProgress = StateObject(wrappedValue: watchProgress)
        let watchHistory = WatchHistoryStore()
        _watchHistory = StateObject(wrappedValue: watchHistory)
        _authStore = StateObject(
            wrappedValue: AuthStore(watchProgress: watchProgress, watchHistory: watchHistory))
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
                .environmentObject(watchHistory)
        }
    }
}
