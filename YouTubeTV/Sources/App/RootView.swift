import SwiftUI

/// Top-level router: shows the login screen until the user is authenticated, then the
/// home feed. Selecting a video — from Home or from Search — presents the full-screen player.
struct RootView: View {
    @EnvironmentObject private var authStore: AuthStore
    @State private var selectedVideo: VideoItem?
    @State private var path: [Destination] = []

    /// Screens reachable from Home. A navigation stack rather than a sheet so the player
    /// cover, attached to the stack, can present over Search too — and so the Menu button
    /// pops back to Home for free, which is what a tvOS user expects.
    private enum Destination: Hashable {
        case search
    }

    var body: some View {
        Group {
            if authStore.isLoggedIn {
                feed
            } else {
                LoginView()
            }
        }
    }

    private var feed: some View {
        NavigationStack(path: $path) {
            HomeView(
                onSelectVideo: { selectedVideo = $0 },
                onOpenSearch: { path.append(.search) }
            )
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .search:
                    SearchView(onSelectVideo: { selectedVideo = $0 })
                }
            }
        }
        .fullScreenCover(item: $selectedVideo) { video in
            PlayerView(
                video: video,
                onClose: {
                    selectedVideo = nil
                })
        }
    }
}
