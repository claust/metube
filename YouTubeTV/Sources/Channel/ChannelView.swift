import SwiftUI

/// One channel: its name and avatar, a subscribe button, and its shelves as feed rows.
///
/// Prototype scope: the first page of shelves only. Rows still page sideways, because YouTube
/// hands a shelf three or four videos and a token — without that a channel looks empty. Paging
/// *down* to further shelves is what Home does and is left out here.
struct ChannelView: View {
    let channelID: String
    /// The channel name from the card the user came from, shown until the channel's own header
    /// arrives — a screen that opens with a blank heading reads as a failed load.
    let fallbackTitle: String

    /// Called when the user picks a video. Wired to the player by the orchestrator, exactly as
    /// Home and Search are.
    var onSelectVideo: (VideoItem) -> Void
    /// Called when a card's menu picks "Go to channel" — a channel's shelves carry other
    /// channels' videos, so this screen can lead to another one.
    var onOpenChannel: (VideoItem) -> Void

    @EnvironmentObject private var authStore: AuthStore
    @EnvironmentObject private var subscriptions: SubscriptionStore

    @State private var title = ""
    @State private var avatarURL: URL?
    @State private var bannerURL: URL?
    @State private var sections: [FeedSection] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    /// The card whose menu is open. A channel's own cards can lead to another channel — a
    /// collaborator, or the channel itself, which is where the menu's subscribe toggle is the
    /// point.
    @State private var menuItem: VideoItem?

    /// Rows currently fetching more videos, by section id, as in `HomeView`.
    @State private var rowsLoadingMore: Set<String> = []
    @State private var rowPagesLoaded: [String: Int] = [:]
    private static let maxRowPages = 10

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            banner

            content
        }
        .videoMenu(for: $menuItem, onOpenChannel: onOpenChannel)
        .task {
            if sections.isEmpty && !isLoading {
                await load()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Loading channel…")
                .font(.title2)
                .tint(.white)
                .foregroundStyle(.white)
        } else if let errorMessage {
            errorView(errorMessage)
        } else {
            rows
        }
    }

    private var rows: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 48) {
                header

                if sections.isEmpty {
                    Text("This channel has nothing to show.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Metrics.horizontalInset)
                } else {
                    ForEach(sections) { section in
                        FeedRow(
                            section: section,
                            onSelectVideo: onSelectVideo,
                            onLongPressVideo: { menuItem = $0 },
                            onNeedMoreItems: { prefetchItemsIfNeeded(in: section.id) }
                        )
                    }
                }
            }
            .padding(.vertical, 60)
        }
    }

    private var header: some View {
        HStack(spacing: 32) {
            avatar
            Text(title.isEmpty ? fallbackTitle : title)
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
            Spacer()
            subscribeButton
        }
        .padding(.horizontal, Metrics.horizontalInset)
        .padding(.top, 20)
        // Keeps left/right presses inside the header rather than dropping into the first row.
        .focusSection()
    }

    /// The channel's own banner, full-bleed behind the header.
    ///
    /// Fixed rather than scrolling: it's the backdrop the header sits on, and the gradient has
    /// reached solid black by the time the first row of cards reaches it, so nothing scrolls
    /// across a lit part of the image. Hidden while loading and on the error screen, both of
    /// which want the plain black background.
    @ViewBuilder
    private var banner: some View {
        if let bannerURL, !isLoading, errorMessage == nil {
            RemoteImage(url: bannerURL) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity.animation(.easeOut(duration: 0.35)))
                }
            }
            .frame(height: Self.bannerHeight)
            .frame(maxWidth: .infinity)
            .clipped()
            // The image is the channel's own artwork, so it can be anything: the scrim keeps
            // white header text readable over a bright banner, and lands on solid black at the
            // bottom so there's no seam where the image ends.
            .overlay(
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.45), location: 0),
                        .init(color: .black.opacity(0.7), location: 0.5),
                        .init(color: .black, location: 0.92),
                        .init(color: .black, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Tall enough to sit behind the header and fade out before the first row, on a 1080p screen.
    private static let bannerHeight: CGFloat = 520

    @ViewBuilder
    private var avatar: some View {
        if let avatarURL {
            RemoteImage(url: avatarURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Color(white: 0.3)
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(Circle())
        }
    }

    /// The same toggle the card menu offers, in the place a channel page is expected to have
    /// one. It reads from the same store, so a change made from either shows up in both.
    private var subscribeButton: some View {
        let isSubscribed = subscriptions.isSubscribed(channelID)
        return Button {
            Task { await subscriptions.setSubscribed(!isSubscribed, channelID: channelID, using: authStore) }
        } label: {
            Label(
                isSubscribed ? "Subscribed" : "Subscribe",
                systemImage: isSubscribed ? "checkmark" : "plus"
            )
            .font(.headline)
        }
        .disabled(subscriptions.isPending(channelID))
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 32) {
            Text("Couldn't load this channel")
                .font(.title)
                .foregroundStyle(.white)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await load() }
            }
            .font(.headline)
        }
        .padding(80)
    }

    @MainActor
    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            guard
                let page = try await authStore.authorized({
                    try await FeedService().loadChannel(id: channelID, accessToken: $0)
                })
            else { return }  // cancelled or signed out

            title = page.title
            avatarURL = page.avatarURL
            bannerURL = page.bannerURL
            sections = page.feed.sections
            rowsLoadingMore = []
            rowPagesLoaded = [:]
            // The channel's own subscribe button is the authoritative answer for this one
            // channel — better than the cached list, which may predate a change made elsewhere.
            if let isSubscribed = page.isSubscribed {
                subscriptions.note(isSubscribed, for: channelID)
            }
        } catch {
            if isCancellation(error) { return }
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Paging one row (scrolling right)

    private func prefetchItemsIfNeeded(in id: String) {
        guard let section = sections.first(where: { $0.id == id }), section.continuation != nil,
            !rowsLoadingMore.contains(id), (rowPagesLoaded[id] ?? 1) < Self.maxRowPages
        else { return }
        Task { await loadMoreItems(in: id) }
    }

    @MainActor
    private func loadMoreItems(in id: String) async {
        // Re-read the row: the trigger's copy is a snapshot, and its token is stale once an
        // earlier page has landed.
        guard let section = sections.first(where: { $0.id == id }), let token = section.continuation,
            !rowsLoadingMore.contains(id), (rowPagesLoaded[id] ?? 1) < Self.maxRowPages
        else { return }

        rowsLoadingMore.insert(id)
        defer { rowsLoadingMore.remove(id) }

        do {
            guard
                let page = try await authStore.authorized({
                    try await FeedService().loadMoreItems(continuation: token, accessToken: $0)
                })
            else { return }

            if append(page.items, continuation: page.continuation, to: id) {
                rowPagesLoaded[id, default: 1] += 1
            }
        } catch {
            if isCancellation(error) { return }
            // Keep what's in the row and stop paging it; the rest of the channel is fine.
            append([], continuation: nil, to: id)
        }
    }

    @MainActor
    @discardableResult
    private func append(_ items: [VideoItem], continuation: String?, to id: String) -> Bool {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return false }
        let section = sections[index]
        let existing = Set(section.items.map(\.id))
        // Shorts belong only in a Shorts row — see `FeedSection.admitting`.
        let fresh = section.admitting(items).filter { !existing.contains($0.id) }
        sections[index] = FeedSection(
            id: id,
            title: section.title,
            items: section.items + fresh,
            // A page that adds nothing new means the row is going in circles: stop, or the last
            // card stays the trigger and refires on every scroll.
            continuation: fresh.isEmpty ? nil : continuation,
            isShorts: section.isShorts
        )
        return true
    }
}
