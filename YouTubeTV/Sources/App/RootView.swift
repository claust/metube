import SwiftUI

/// Top-level router: shows the login screen until the user is authenticated, then the
/// home feed. Selecting a video presents the full-screen player.
struct RootView: View {
    @EnvironmentObject private var authStore: AuthStore
    @State private var selectedVideo: VideoItem?

    var body: some View {
        Group {
            if authStore.isLoggedIn {
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
}
