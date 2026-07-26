import SwiftUI

@main
struct YouTubeTVApp: App {
    @StateObject private var authStore = AuthStore()
    @StateObject private var watchProgress = WatchProgressStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authStore)
                .environmentObject(watchProgress)
        }
    }
}
