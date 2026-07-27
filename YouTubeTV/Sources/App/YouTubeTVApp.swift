import SwiftUI

@main
struct YouTubeTVApp: App {
    @StateObject private var authStore: AuthStore
    @StateObject private var watchProgress: WatchProgressStore

    /// Built here rather than with property initialisers because the two are connected: the
    /// profile store tells the progress store when a profile's history is migrated, moved or
    /// deleted, and that has to reach the same instance the views are reading.
    @MainActor
    init() {
        let watchProgress = WatchProgressStore()
        _watchProgress = StateObject(wrappedValue: watchProgress)
        _authStore = StateObject(wrappedValue: AuthStore(watchProgress: watchProgress))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authStore)
                .environmentObject(watchProgress)
        }
    }
}
