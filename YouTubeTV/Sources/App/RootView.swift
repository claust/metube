import SwiftUI
import TVServices

/// Top-level router: shows the login screen until a profile is signed in, then that profile's
/// home feed. Selecting a video — from Home or from Search — presents the full-screen player,
/// and the plus in the profile bar presents the login screen again to add another account.
/// A Top Shelf tile arrives here too, as a `metube://` URL that opens the same player.
struct RootView: View {
    @EnvironmentObject private var authStore: AuthStore
    @EnvironmentObject private var watchProgress: WatchProgressStore
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @State private var selectedVideo: VideoItem?
    @State private var path: [Destination] = []
    @State private var isAddingProfile = false

    /// Screens reachable from Home. A navigation stack rather than a sheet so the player
    /// cover, attached to the stack, can present over Search too — and so the Menu button
    /// pops back to Home for free, which is what a tvOS user expects.
    private enum Destination: Hashable {
        case search
        /// A channel, carrying the name of the card it was opened from so the screen has a
        /// heading before its own header arrives.
        case channel(id: String, title: String)
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
        .onChange(of: authStore.activeProfileID, initial: true) { previous, profileID in
            watchProgress.activate(profileID: profileID)
            // Subscriptions belong to an account just as history does, so the card menus follow
            // the active profile rather than showing the previous one's Subscribe/Unsubscribe.
            subscriptions.activate(profileID: profileID)
            // Nobody is signed in any more, so the tiles on the home screen would be the last
            // account's recommendations sitting there for whoever walks past.
            if profileID == nil {
                TopShelfStore.clear()
                TVTopShelfContentProvider.topShelfContentDidChange()
            }
            // Switching profiles (or signing the last one out) swaps the view but not this
            // state, so without resetting it a session that ended mid-search would reopen
            // straight into Search — or re-present the previous profile's video. Skipped on the
            // initial run, where `previous` is the current value and there is nothing to reset:
            // a launch from a Top Shelf tile has already set `selectedVideo` by this point.
            guard previous != profileID else { return }
            path = []
            selectedVideo = nil
        }
        .onOpenURL { url in
            openTopShelfVideo(url)
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
                onAddProfile: { isAddingProfile = true },
                onOpenChannel: openChannel
            )
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .search:
                    SearchView(onSelectVideo: { selectedVideo = $0 }, onOpenChannel: openChannel)
                case .channel(let id, let title):
                    ChannelView(
                        channelID: id,
                        fallbackTitle: title,
                        onSelectVideo: { selectedVideo = $0 },
                        onOpenChannel: openChannel
                    )
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

    /// Opens the video behind a Top Shelf tile, straight into the player.
    ///
    /// The tile only carries a video id, so the rest of the card comes back out of the same
    /// snapshot the extension drew it from — that way the player's loading overlay shows the
    /// title the user just pressed rather than a blank. A tile whose snapshot has since been
    /// replaced still plays; it just opens untitled.
    ///
    /// Ignored while signed out: there is no token to resolve a stream with, and dropping the
    /// user on the sign-in screen is a truer answer than a player that can only fail.
    private func openTopShelfVideo(_ url: URL) {
        guard authStore.isLoggedIn, let videoID = TopShelfLink.videoID(from: url) else { return }
        let known = TopShelfStore.videos.first { $0.id == videoID }
        // Replaces whatever was on screen: pressing a tile is a fresh intent, and tvOS delivers
        // it to an app that may still be sitting where it was left.
        selectedVideo = VideoItem(
            id: videoID,
            title: known?.title ?? "",
            author: known?.author ?? "",
            thumbnailURL: known?.thumbnailURL
        )
    }

    /// Pushes the channel a card came from. A card whose cell never linked one can't get here —
    /// the menu doesn't offer the option — so this quietly does nothing in that case.
    private func openChannel(_ video: VideoItem) {
        guard let channelID = video.channelID else { return }
        path.append(.channel(id: channelID, title: video.author))
    }
}
