import SwiftUI

/// Top-level router: shows the login screen until the user is authenticated, then the
/// home feed. Selecting a video presents the full-screen player.
struct RootView: View {
    @EnvironmentObject private var authStore: AuthStore
    @State private var selectedVideo: VideoItem?

    var body: some View {
        Group {
            if authStore.isLoggedIn || isMockFeed {
                HomeView(onSelectVideo: { video in
                    selectedVideo = video
                })
                .fullScreenCover(item: $selectedVideo) { video in
                    PlayerView(
                        video: video,
                        onClose: {
                            selectedVideo = nil
                        })
                }
            } else {
                LoginView()
            }
        }
    }

    /// Debug builds launched with `-mockFeed` go straight to a canned Home, so layout work
    /// can be seen on the simulator without signing in. Always false in release builds.
    private var isMockFeed: Bool {
        #if DEBUG
        return MockFeed.isEnabled
        #else
        return false
        #endif
    }
}
