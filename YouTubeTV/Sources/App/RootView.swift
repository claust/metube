import SwiftUI
import TVServices

/// Top-level router: shows the login screen until a profile is signed in, then that profile's
/// home feed. Selecting a video — from Home or from Search — presents the full-screen player,
/// and the plus in the profile bar presents the login screen again to add another account.
/// A Top Shelf tile arrives here too, as a `metube://` URL that opens the same player.
struct RootView: View {
    @EnvironmentObject private var authStore: AuthStore
    @EnvironmentObject private var watchProgress: WatchProgressStore
    @EnvironmentObject private var watchProgressSync: WatchProgressSync
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @EnvironmentObject private var watchHistory: WatchHistoryStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedVideo: VideoItem?
    @State private var path: [Destination] = []
    @State private var isAddingProfile = false

    /// Which of the left menu's screens is showing. Home is the feed the app has always opened
    /// on, Subscriptions is the channel grid, History is what has been watched; Settings is still
    /// an outline — see `MenuPlaceholderPage`.
    @State private var section: MenuSection = .home

    /// Bumped every time the menu picks a section. The screen it selects answers by taking
    /// focus — onto its first card, or onto the page itself where there are no cards yet —
    /// which is what closes the menu behind the press.
    @State private var focusRequest = 0

    /// True once Home's first page has settled. The menu is out of the focus engine's reach
    /// until then, so the app opens on the feed rather than on a menu that took the focus by
    /// default for want of anything else to give it to.
    @State private var isFeedReady = false

    /// True while the left menu holds focus. Dims the screen behind it, so the panel reads as
    /// being over the feed rather than beside it.
    @State private var isMenuExpanded = false

    /// True while Home's news banner is in use — see `HomeView.onNewsActiveChange`. Left and
    /// right in the banner step between headlines, and the menu is what sits to the left of it,
    /// so it stands down for as long as the banner has focus.
    @State private var isNewsActive = false

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
        // The clock rides above everything on this screen rather than inside the Home header,
        // so it stays put while the feed scrolls and is still there on Search and Channel.
        // Deliberately outside the safe area: the ask is a corner clock, and the tvOS inset
        // would park it level with the header instead. The player, presented as a cover of its
        // own, is above this overlay and stays uncluttered.
        .overlay(alignment: .topTrailing) {
            ClockView()
                // Uneven on purpose, so the *digits* sit the same distance from both edges:
                // the text box carries about 12pt of ascender space above the numerals that
                // the right edge has no equivalent of.
                .padding(.top, 36)
                .padding(.trailing, 46)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .ignoresSafeArea()
        }
        // Watch history belongs to a profile, so the store follows the active one. Also runs on
        // first appear, which is what loads the history at launch.
        .onChange(of: authStore.activeProfileID, initial: true) { previous, profileID in
            watchProgress.activate(profileID: profileID)
            // And is backed up for that profile, so a reinstall doesn't start from nothing.
            // Ordered after `activate`: the sync merges into whatever history is loaded now.
            watchProgressSync.activate(
                profile: authStore.activeProfile, accessToken: authStore.accessToken)
            // Subscriptions belong to an account just as history does, so the card menus follow
            // the active profile rather than showing the previous one's Subscribe/Unsubscribe.
            subscriptions.activate(profileID: profileID)
            // And so does what has been watched on this TV — the History screen shows the profile
            // in the bar, not everything the box has ever played.
            watchHistory.activate(profileID: profileID)
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
        // A profile carried over from an older build, or added while the account menu was
        // unreachable, has no account key until `backfillAccountInfo` supplies one — and
        // without it the backend has nothing to verify the profile's identity against. This
        // starts the sync the moment that arrives, rather than at the next profile switch.
        .onChange(of: authStore.activeProfile?.accountKey) { _, _ in
            watchProgressSync.activate(
                profile: authStore.activeProfile, accessToken: authStore.accessToken)
        }
        // Coming back: another Apple TV may have watched something in the meantime. Leaving:
        // push whatever the debounce is still sitting on, because a suspended app may never
        // get another chance.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: watchProgressSync.sync()
            default: watchProgressSync.flushNow()
            }
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
            shell
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

    /// The menu and the screen it selects, side by side.
    ///
    /// A real `HStack` rather than an overlay, because the focus engine moves by geometry: two
    /// regions that overlap are not to the left and right of each other, and a left press off
    /// the first card of a row would have nowhere to go. So the menu claims its rail's width
    /// from the layout, and only the panel it opens into is drawn over the screen beside it.
    private var shell: some View {
        HStack(spacing: 0) {
            SideMenu(
                section: $section,
                canTakeFocus: isFeedReady && !isNewsActive,
                onExpandedChange: { isMenuExpanded = $0 },
                onSelect: { focusRequest += 1 }
            )
            // The menu is painted first but has to end up on top: its expanded panel is
            // wider than the width claimed here and hangs over the screen beside it.
            .zIndex(1)

            ZStack {
                // Kept in the tree behind the other sections rather than swapped out, so a
                // look at Settings doesn't cost a full reload of the feed — and so coming
                // back lands on the same shelves, scrolled where they were left. Hidden it is
                // also disabled, which is what keeps its cards out of the focus engine's
                // reach while something else is on screen.
                HomeView(
                    // Home is only in front when nothing is presented over it — and now, when
                    // it is the section on screen at all. It uses this to decide when looking
                    // for a fresher feed is worthwhile, and more to the point never applies
                    // one while a video is playing.
                    isFrontmost: selectedVideo == nil && path.isEmpty && section == .home,
                    onSelectVideo: { selectedVideo = $0 },
                    onOpenSearch: { path.append(.search) },
                    onAddProfile: { isAddingProfile = true },
                    onOpenChannel: openChannel,
                    onLoadFinished: { isFeedReady = true },
                    onNewsActiveChange: { isNewsActive = $0 },
                    focusRequest: focusRequest
                )
                .opacity(section == .home ? 1 : 0)
                .disabled(section != .home)

                switch section {
                case .home:
                    EmptyView()
                case .subscriptions:
                    SubscriptionsView(
                        focusRequest: focusRequest,
                        onOpenChannel: { path.append(.channel(id: $0.id, title: $0.displayName)) }
                    )
                case .history:
                    HistoryView(
                        focusRequest: focusRequest,
                        onSelectVideo: { selectedVideo = $0 },
                        onOpenChannel: openChannel
                    )
                case .settings:
                    MenuPlaceholderPage(section: section, focusRequest: focusRequest)
                }
            }
            // Reading the menu against a screenful of bright thumbnails is otherwise a fight
            // the menu loses, and on the quieter screens it still says which of the two the
            // presses are going to.
            .opacity(isMenuExpanded ? 0.55 : 1)
            .animation(.easeOut(duration: 0.22), value: isMenuExpanded)
        }
        .background(Color.black.ignoresSafeArea())
        // Menu on the remote means "back" — on a prototype screen that is Home, which is the
        // only thing back can mean at the root of the stack. Left alone tvOS would take it as
        // "leave the app" while the user is two presses into a menu they just opened.
        // `nil` on Home rather than an empty closure: a handler that does nothing still eats
        // the press, and Menu at the root of the app is how you leave it.
        .onExitCommand(perform: section == .home ? nil : { section = .home })
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
