import SwiftUI

/// Top-level router: shows the login screen until a profile is signed in, then that profile's
/// home feed. Selecting a video — from Home or from Search — presents the full-screen player,
/// and the plus in the profile bar presents the login screen again to add another account.
struct RootView: View {
    @EnvironmentObject private var authStore: AuthStore
    @EnvironmentObject private var watchProgress: WatchProgressStore
    @State private var selectedVideo: VideoItem?
    @State private var path: [Destination] = []
    @State private var isAddingProfile = false

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
        // Watch history belongs to a profile, so the store follows the active one. Also runs on
        // first appear, which is what loads the history at launch.
        .onChange(of: authStore.activeProfileID, initial: true) { _, profileID in
            watchProgress.activate(profileID: profileID)
            // Switching profiles (or signing the last one out) swaps the view but not this
            // state, so without resetting it a session that ended mid-search would reopen
            // straight into Search — or re-present the previous profile's video.
            path = []
            selectedVideo = nil
        }
        // Names and avatars for profiles that don't have them yet — one carried over from the
        // single-account build, or added while the account menu was unreachable.
        .task { await authStore.backfillAccountInfo() }
        .fullScreenCover(isPresented: $isAddingProfile) {
            LoginView(onDismiss: { isAddingProfile = false })
        }
    }

    private var feed: some View {
        NavigationStack(path: $path) {
            HomeView(
                onSelectVideo: { selectedVideo = $0 },
                onOpenSearch: { path.append(.search) },
                onAddProfile: { isAddingProfile = true }
            )
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .search:
                    SearchView(onSelectVideo: { selectedVideo = $0 })
                }
            }
        }
        // Each profile gets its own feed: rebuilding on a switch reloads the shelves for the
        // account now signed in, which a view that already loaded once would not do.
        .id(authStore.activeProfileID)
        .fullScreenCover(item: $selectedVideo) { video in
            PlayerView(
                video: video,
                onClose: {
                    selectedVideo = nil
                })
        }
    }
}
