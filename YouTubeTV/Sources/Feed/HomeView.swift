import Foundation
import SwiftUI
import TVServices

/// The personalized Home feed: one horizontal, focusable row per YouTube shelf.
/// Selection is delegated to the orchestrator via `onSelectVideo`.
struct HomeView: View {
    /// True while Home itself is the screen in front — no player, no Search over it. The
    /// staleness check below only runs when this holds, and the button it can raise is only
    /// reachable then anyway.
    var isFrontmost: Bool
    /// Called when the user chooses a video. The orchestrator wires this to the player.
    var onSelectVideo: (VideoItem) -> Void
    /// Called when the user picks the search icon. The orchestrator wires this to `SearchView`.
    var onOpenSearch: () -> Void
    /// Called when the user picks the plus in the profile bar. The orchestrator wires this to
    /// the sign-in screen.
    var onAddProfile: () -> Void
    /// Called when a card's menu picks "Go to channel". The orchestrator wires this to
    /// `ChannelView`.
    var onOpenChannel: (VideoItem) -> Void

    @EnvironmentObject private var authStore: AuthStore
    @EnvironmentObject private var channelAvatars: ChannelAvatarStore
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @Environment(\.scenePhase) private var scenePhase

    /// The card whose menu is open, and `nil` when none is. Held here rather than in the card
    /// so one dialog serves every row.
    @State private var menuItem: VideoItem?

    /// True while the news panel is being read — see `NewsBanner.isFeedLocked`. Holds this
    /// screen's scroll view still so that scrolling the article doesn't scroll the feed too.
    @State private var isFeedScrollLocked = false

    /// Focus handle for the very first video card. Set when the news panel is dismissed with
    /// Menu, which is the one moment something other than the focus engine decides where focus
    /// belongs: the user asked to leave the news, and the feed's first card is where they were
    /// heading.
    @FocusState private var isFirstCardFocused: Bool

    @State private var sections: [FeedSection] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    /// Headlines for the ticker across the top. Independent of the feed in every way — public
    /// RSS, no token — so an empty or failed fetch just leaves the strip off rather than
    /// affecting Home.
    @State private var headlines: [NewsItem] = []

    /// How old the headlines have to be before refetching them. BBC's feed declares a 15-minute
    /// `<ttl>`; matching it means the refetch is usually served from cache and costs nothing.
    private static let headlinesStaleAfter: TimeInterval = 15 * 60
    /// When the headlines on screen were fetched. `nil` until the first load.
    @State private var headlinesLoaded: Date?

    /// Fresher headlines, fetched while the ticker was in use and deliberately not applied.
    ///
    /// Swapping the list out from under someone mid-story is the one thing a ticker must not
    /// do: the strip is keyed by headline, so a new list restarts the scroll, and the article
    /// being read would be replaced by whatever now sits at that position. These wait for the
    /// user to step out of the banner, which is a moment where nothing is lost.
    @State private var pendingHeadlines: [NewsItem] = []

    /// True while the strip is focused or a story is open — see `NewsBanner.onActiveChange`.
    @State private var isNewsActive = false

    /// True between Menu being pressed in the news panel and focus arriving on the first card.
    /// Drives the handoff below.
    @State private var isHandingBackFocus = false

    /// Guards against two headline fetches running at once. The poll below and the return from
    /// the background can both come due in the same moment, and `headlinesLoaded` is only
    /// written when a fetch lands — so without this they would both pass the staleness check and
    /// both go to the network for the same answer.
    @State private var isLoadingHeadlines = false

    /// How often to look for newer headlines while Home is sitting on screen. The check itself
    /// is cheap and usually finds nothing — `headlinesStaleAfter` decides whether it goes to the
    /// network at all — but without it a TV left on Home would still be showing this morning's
    /// news tonight.
    private static let headlinesPollInterval: TimeInterval = 5 * 60

    /// Whether the headline poll should be running at all: Home in front, app in the foreground.
    ///
    /// Read as a `.task` id rather than checked inside the loop. A long-lived task captures the
    /// view as it was when the task started, so a flag tested inside it would answer with the
    /// value from minutes ago — the id is what actually notices the change, by cancelling the
    /// task and starting a fresh one.
    private var isPollingHeadlines: Bool { scenePhase == .active && isFrontmost }

    /// Rows from the supplementary feeds, by feed. Kept separate from `sections` — and from each
    /// other — so each one lands in its own slot in the layout and stays there as Home pages,
    /// rather than being pushed around by it.
    @State private var feedSections: [Feed: [FeedSection]] = [:]

    /// Token for the next page of shelves; `nil` once the feed is exhausted or paging has stopped.
    @State private var continuation: String?
    @State private var isLoadingMore = false
    @State private var pagesLoaded = 0

    /// When Home's shelves last landed — the first page, or a pending page applied. `nil` until
    /// the first load, which is what keeps the staleness check from firing before there is a
    /// feed to compare against.
    @State private var lastLoaded: Date?

    /// A newer feed, fetched in the background and deliberately *not* applied.
    ///
    /// Swapping it in unprompted would move the ground under someone who just came back from a
    /// video: shelf ids are fresh per load, so a swap rebuilds every row, and the card they
    /// meant to play next — the one to the right of what they just watched — may not even be in
    /// the new feed. So it waits behind a button in the header and the user picks the moment.
    @State private var pendingPage: FeedPage?
    /// How many of `pendingPage`'s videos aren't on screen yet. Drives the button's label, and
    /// being zero is how we tell "the feed moved on" from "nothing has changed".
    @State private var pendingNewCount = 0
    /// Guards against a second background check while one is in flight.
    @State private var isCheckingForNew = false

    /// How old the feed has to be before a background check is worth a request. Home doesn't
    /// turn over fast enough for anything shorter to find much.
    private static let staleAfter: TimeInterval = 15 * 60

    /// Rows currently fetching more videos, by section id. Guards against the same row firing
    /// several requests while one is in flight — cards reappear constantly while scrolling.
    @State private var rowsLoadingMore: Set<String> = []
    /// Pages fetched per row, by section id. Absent means the row is still on its first page.
    @State private var rowPagesLoaded: [String: Int] = [:]

    /// A backstop on runaway paging — home is effectively endless, and each page costs a
    /// request plus a screenful of thumbnails.
    private static let maxPages = 8

    /// The same backstop for one row. A row page carries ~10 videos, so this caps a row at
    /// roughly 100 — far more than anyone scrolls through, and still bounded.
    private static let maxRowPages = 10

    /// Start fetching the next page once a row this close to the end comes into view.
    private static let prefetchDistance = 2

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            content
        }
        .videoMenu(for: $menuItem, onOpenChannel: onOpenChannel)
        .task {
            // Load once on first appear.
            if sections.isEmpty && !isLoading {
                await load()
            }
        }
        // Headlines are fetched alongside the feed rather than as part of it — a slow or dead
        // news feed must not hold up the videos, and this needs no sign-in. Then kept up to date
        // for as long as Home is actually in front, which on a TV can be all evening; a video
        // playing over it stops the polling rather than quietly fetching news behind the player.
        // Coming back restarts the task, and the staleness check makes that first pass free
        // unless the headlines really have aged out.
        .task(id: isPollingHeadlines) {
            guard isPollingHeadlines else { return }
            await loadHeadlinesIfStale()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.headlinesPollInterval))
                guard !Task.isCancelled else { return }
                await loadHeadlinesIfStale()
            }
        }
        // Focus back to the feed a beat after Menu, once the banner has let go and the first
        // shelf is on screen and built again — asking any sooner finds no card to focus.
        //
        // Held by the view rather than by a detached `Task` so it dies with Home, and re-checked
        // on the way out: 120ms is long enough for the user to have gone straight back up into
        // the ticker, and this must not then yank them out of it.
        .task(id: isHandingBackFocus) {
            guard isHandingBackFocus else { return }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            if !isNewsActive { isFirstCardFocused = true }
            isHandingBackFocus = false
        }
        // Stepping out of the banner is the safe moment to swap in anything that arrived while
        // it was in use.
        .onChange(of: isNewsActive) { _, active in
            if !active, !pendingHeadlines.isEmpty {
                headlines = pendingHeadlines
                pendingHeadlines = []
            }
        }
        // Coming back from a spell in another app is the safest moment to look: whatever the
        // user was doing here, they left and returned to it.
        .onChange(of: scenePhase) { _, phase in
            // Headlines are not refreshed here: coming back to the foreground flips
            // `isPollingHeadlines`, which restarts the poll task and checks them on its way in.
            if phase == .active { checkForNewVideosIfStale() }
        }
        // Returning from the player or Search is the one moment a refresh must never *apply* —
        // but it is a fine moment to look, so the button is already waiting if the feed moved
        // on while a long video played. `checkForNewVideos` only ever fills `pendingPage`.
        .onChange(of: isFrontmost) { _, frontmost in
            if frontmost { checkForNewVideosIfStale() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Loading your feed…")
                .font(.title2)
                .tint(.white)
                .foregroundStyle(.white)
        } else if let errorMessage {
            errorView(errorMessage)
        } else {
            feedRows
        }
    }

    private var feedRows: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 48) {
                if !headlines.isEmpty {
                    NewsBanner(
                        items: headlines,
                        onFeedLockChange: { isFeedScrollLocked = $0 },
                        onActiveChange: { isNewsActive = $0 },
                        onDismiss: { isHandingBackFocus = true }
                    )
                    .padding(.horizontal, Metrics.horizontalInset)
                    // Clears the clock, which floats over this screen's top-right corner
                    // outside the safe area and would otherwise sit on the strip. Kept tight
                    // for the reason in `NewsBanner.panelHeight`: every point here is a point
                    // of slack the open panel doesn't have at the bottom.
                    .padding(.top, 24)
                    // The strip handles left/right itself, stepping between headlines —
                    // this stops those presses escaping into the header below it.
                    .focusSection()
                }

                HStack(spacing: 24) {
                    Text("Home")
                        .font(.system(size: 56, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    // Only here once a background check has found something. It sits in the
                    // header, which is only on screen at the top of the feed — so reaching it
                    // already means the user has left whatever row they were in.
                    if pendingNewCount > 0 {
                        Button(action: applyPendingPage) {
                            Label(
                                pendingNewCount == 1 ? "1 new video" : "\(pendingNewCount) new videos",
                                systemImage: "arrow.clockwise"
                            )
                            .font(.title3.weight(.semibold))
                        }
                        .accessibilityLabel("Show new videos")
                    }
                    Button(action: onOpenSearch) {
                        Image(systemName: "magnifyingglass")
                            .font(.title2.weight(.semibold))
                    }
                    // The glyph carries no text, so name it for VoiceOver and the UI tests.
                    .accessibilityLabel("Search")
                    ProfileBar(onAddProfile: onAddProfile)
                }
                .padding(.horizontal, Metrics.horizontalInset)
                .padding(.top, 20)
                // Keeps left/right presses inside the header instead of dropping into the
                // first row, which sits directly beneath it.
                .focusSection()

                if sections.isEmpty && supplementarySections.isEmpty {
                    Text("No recommendations found.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Metrics.horizontalInset)
                        .padding(.top, 40)
                } else {
                    ForEach(leadSections) { homeRow($0) }

                    // Directly under the recommendations, which is the whole point of splitting
                    // Home in two: what the user actually subscribed to shouldn't sit below
                    // however many shelves YouTube chose to send, let alone below eight pages
                    // of them.
                    ForEach(feedSections[.subscriptions] ?? []) { supplementaryRow($0) }

                    ForEach(trailingSections) { homeRow($0) }

                    // Sits at the end of Home, where the next page lands.
                    if isLoadingMore {
                        ProgressView()
                            .tint(.white)
                            .padding(.horizontal, Metrics.horizontalInset)
                    }

                    ForEach(feedSections[.history] ?? []) { supplementaryRow($0) }
                }
            }
            .padding(.vertical, 60)
        }
        // Held still while a news story is being read, so the article scrolls inside its panel
        // instead of taking the whole feed with it.
        .scrollDisabled(isFeedScrollLocked)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 32) {
            Text("Couldn't load your feed")
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

    /// Fetches the headlines, unless the ones on screen are still fresh. Failure is silent by
    /// design: the ticker is a garnish on someone's video feed, and an error banner about the
    /// news would be a worse thing to look at than no news.
    @MainActor
    private func loadHeadlinesIfStale() async {
        if let headlinesLoaded, Date().timeIntervalSince(headlinesLoaded) < Self.headlinesStaleAfter {
            return
        }
        guard !isLoadingHeadlines else { return }
        isLoadingHeadlines = true
        defer { isLoadingHeadlines = false }

        let items = await NewsService().headlines()
        // Nothing came back — every source failed, or the feed is empty. Deliberately *not*
        // counted as loaded, so the next poll tries again in five minutes rather than sitting on
        // the stale headlines for the full fifteen. The headlines already on screen stay there
        // in the meantime.
        guard !items.isEmpty else { return }
        // A fetch that returned something counts as loaded whether or not it was applied on the
        // spot: refetching every poll while someone reads a long article would cost the same
        // request for the same answer.
        headlinesLoaded = Date()
        if isNewsActive {
            pendingHeadlines = items
        } else {
            headlines = items
        }
    }

    @MainActor
    private func load() async {
        guard authStore.accessToken != nil else {
            errorMessage = "You're not signed in."
            return
        }
        guard await loadHomeFirstPage() else { return }

        // Which channels the account follows, so the first card menu the user opens is labelled
        // from the account rather than from the last launch's cache. Off the critical path —
        // the cache already has an answer, and this only corrects it.
        Task { await subscriptions.refresh(using: authStore) }

        // The spinner is already gone and Home's shelves are on screen, so a slow
        // Subscriptions or History request delays only its own rows. Home also just
        // succeeded, which means the token is good — no need to repeat the refresh dance.
        if let token = authStore.accessToken {
            await loadSupplementaryFeeds(accessToken: token)
        }
    }

    /// Loads Home's first page. Returns `false` when nothing landed — an error, a cancellation,
    /// or a sign-out — in which case the caller should not go on to the supplementary feeds.
    @MainActor
    private func loadHomeFirstPage() async -> Bool {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            guard
                let page = try await authStore.authorized({
                    try await FeedService().loadHome(accessToken: $0)
                })
            else {
                return false  // cancelled or signed out — nothing to show and nothing to report
            }
            sections = page.sections
            continuation = page.continuation
            pagesLoaded = 1
            updateTopShelf(from: page.sections)
            lastLoaded = .now
            // A pending page fetched before this one is now older than what's on screen.
            pendingPage = nil
            pendingNewCount = 0
            // Section ids are fresh UUIDs on every load, so a reload (Retry, sign-in again)
            // would otherwise leave this state keyed to rows that no longer exist. The
            // supplementary feeds reload right after this, so one reset covers both lists.
            rowsLoadingMore = []
            rowPagesLoaded = [:]
            return true
        } catch {
            if isCancellation(error) { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Fetches Subscriptions and History concurrently and fills their slots around Home.
    /// Each feed degrades on its own: one failing or being slow leaves the others (and Home)
    /// unaffected, because rows are published as each feed arrives rather than in one batch.
    @MainActor
    private func loadSupplementaryFeeds(accessToken: String) async {
        var loaded: [Feed: [FeedSection]] = [:]
        await withTaskGroup(of: (Feed, FeedPage?).self) { group in
            for feed in Self.supplementaryFeeds {
                group.addTask {
                    (feed, try? await FeedService().loadFeed(feed, accessToken: accessToken))
                }
            }
            for await (feed, page) in group {
                guard !Task.isCancelled else { return }
                loaded[feed] = page?.sections ?? []
                // Subscriptions is the one response that pictures channels; the cards read the
                // pictures back by name, so they light up as soon as this lands.
                channelAvatars.merge(page?.channelAvatars ?? [:])
                // Publish what has arrived. Which feed a row belongs to now decides where it is
                // drawn, so the order the requests finish in doesn't affect the layout — a feed
                // still pending just leaves its slot empty for now.
                feedSections = loaded
            }
        }
    }

    // MARK: - Refreshing

    /// Starts a background check if the feed is old enough to be worth one.
    ///
    /// Deliberately not gated on where the user has scrolled to: the check never touches what's
    /// on screen, so it is safe to run from anywhere in the feed, and by the time they scroll
    /// back up the button is already there.
    private func checkForNewVideosIfStale() {
        guard isFrontmost, !isLoading, !isCheckingForNew, pendingPage == nil,
            let lastLoaded, Date.now.timeIntervalSince(lastLoaded) > Self.staleAfter
        else { return }
        Task { await checkForNewVideos() }
    }

    /// Fetches Home's first page and parks it in `pendingPage` if it carries videos that aren't
    /// on screen. Never touches `sections` — applying is `applyPendingPage`, and only the user
    /// triggers that.
    @MainActor
    private func checkForNewVideos() async {
        isCheckingForNew = true
        defer { isCheckingForNew = false }

        // A background check the user never asked for; failing it silently and trying again
        // later is right. In particular it must not raise `errorMessage`, which would replace
        // a perfectly good feed with an error screen.
        guard
            let page = try? await authStore.authorized({
                try await FeedService().loadHome(accessToken: $0)
            }) ?? nil
        else { return }

        let shown = Set((sections + supplementarySections).flatMap { $0.items.map(\.id) })
        // Counted over a set: Home repeats the same video across shelves, and "3 new videos"
        // should mean three of them.
        let fresh = Set(page.sections.flatMap { $0.items.map(\.id) }).subtracting(shown)

        guard !fresh.isEmpty else {
            // Nothing new. Treat the feed as fresh again, or every return from a video would
            // spend another request rediscovering that.
            lastLoaded = .now
            return
        }

        pendingPage = page
        pendingNewCount = fresh.count
    }

    /// Swaps the pending feed in. Called only from the header button — see `pendingPage` for
    /// why this never happens on its own.
    @MainActor
    private func applyPendingPage() {
        guard let page = pendingPage else { return }
        pendingPage = nil
        pendingNewCount = 0

        sections = page.sections
        continuation = page.continuation
        pagesLoaded = 1
        lastLoaded = .now
        // The feed the tiles were cut from has just been replaced, so cut them again — the
        // whole point of this button is that Home now leads with different videos.
        updateTopShelf(from: page.sections)
        // Same reason as the first load: every row id is new, so state keyed to the old ones
        // would point at rows that no longer exist.
        rowsLoadingMore = []
        rowPagesLoaded = [:]

        // Only Home was fetched; the Subscriptions and History rows below it are still the ones
        // from the last load, so bring them up to date too. They land row by row, as on launch.
        if let token = authStore.accessToken {
            Task { await loadSupplementaryFeeds(accessToken: token) }
        }
        // As on first load: the account may have followed a channel elsewhere since, and this is
        // the moment the feed catches up with it.
        Task { await subscriptions.refresh(using: authStore) }
    }

    /// In a LazyVStack this runs as a row scrolls into view. Paging starts while there are
    /// still rows below, so reaching the bottom doesn't stall on a network round-trip —
    /// waiting for the genuinely last row would make the delay visible every time.
    private func prefetchIfNeeded(from section: FeedSection) {
        // Rows reappear constantly while scrolling, so check the cheap conditions before
        // spawning a Task that loadMore() would only bail out of anyway.
        guard continuation != nil, !isLoadingMore, pagesLoaded < Self.maxPages else { return }
        guard let index = sections.firstIndex(where: { $0.id == section.id }),
            index >= sections.count - Self.prefetchDistance
        else { return }
        Task { await loadMore() }
    }

    /// Appends the next page of shelves.
    @MainActor
    private func loadMore() async {
        guard let token = continuation, !isLoadingMore, pagesLoaded < Self.maxPages else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            guard
                let page = try await authStore.authorized({
                    try await FeedService().loadMore(continuation: token, accessToken: $0)
                })
            else { return }

            pagesLoaded += 1
            let fresh = newSections(in: page.sections)
            sections.append(contentsOf: fresh)
            // If a page adds nothing, stop — the trigger row would otherwise stay last and
            // refire on every scroll, paging forever with no visible progress.
            continuation = fresh.isEmpty ? nil : page.continuation
        } catch {
            if isCancellation(error) { return }
            // A failed page shouldn't wipe out the feed already on screen. Give up on paging
            // and leave what's loaded intact.
            continuation = nil
        }
    }

    // MARK: - Paging one row (scrolling right)

    /// Runs as a card near the end of a row scrolls into view. YouTube seeds each shelf with
    /// only a handful of videos, so without this a row ends after five cards.
    /// Takes an id rather than the row itself: the caller's copy can be a page behind, and
    /// acting on its token would spawn a Task for a row that is already exhausted.
    private func prefetchItemsIfNeeded(in id: String) {
        guard let section = section(withID: id), section.continuation != nil,
            !rowsLoadingMore.contains(id), (rowPagesLoaded[id] ?? 1) < Self.maxRowPages
        else { return }
        Task { await loadMoreItems(in: id) }
    }

    /// Appends the next batch of videos to one row.
    @MainActor
    private func loadMoreItems(in id: String) async {
        // Re-read the row: the caller's copy is a snapshot, and its token is stale once an
        // earlier page has landed.
        guard let section = self.section(withID: id), let token = section.continuation,
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

            // Only count the page if the row is still there. A reload during the request
            // replaces every section, and re-keying this to a row that no longer exists would
            // leak an entry the reset above can no longer reach.
            if append(page.items, continuation: page.continuation, to: id) {
                rowPagesLoaded[id, default: 1] += 1
            }
        } catch {
            if isCancellation(error) { return }
            // Keep what's already in the row and stop paging it; the rest of the feed is fine.
            append([], continuation: nil, to: id)
        }
    }

    private func section(withID id: String) -> FeedSection? {
        sections.first { $0.id == id } ?? supplementarySections.first { $0.id == id }
    }

    /// Adds videos to the row with this id, in whichever list holds it. Returns `false` when
    /// no such row is on screen any more — a reload replaced it while the request was in flight.
    @MainActor
    @discardableResult
    private func append(_ items: [VideoItem], continuation: String?, to id: String) -> Bool {
        func update(_ list: inout [FeedSection]) -> Bool {
            guard let index = list.firstIndex(where: { $0.id == id }) else { return false }
            let section = list[index]
            let existing = Set(section.items.map(\.id))
            // Shorts belong only in a Shorts row, on a page as much as on the first load — see
            // `FeedSection.admitting`.
            let fresh = section.admitting(items).filter { !existing.contains($0.id) }
            list[index] = FeedSection(
                id: id,
                title: section.title,
                items: section.items + fresh,
                // A page that adds nothing new means the row is going in circles: stop, or the
                // last card stays the trigger and refires on every scroll.
                continuation: fresh.isEmpty ? nil : continuation,
                isShorts: section.isShorts
            )
            return true
        }
        if update(&sections) { return true }
        for feed in Self.supplementaryFeeds {
            guard var rows = feedSections[feed] else { continue }
            guard update(&rows) else { continue }
            feedSections[feed] = rows
            return true
        }
        return false
    }

    /// Hands the feed's first couple of videos to the Top Shelf extension, which draws them
    /// above the app's icon on the tvOS home screen.
    ///
    /// Written here, on every successful first page, because this is the only point where the
    /// active profile's feed is known to be current — the extension has no token of its own and
    /// only ever reads what this leaves behind. Flattening the shelves rather than taking the
    /// first one's items means a lead shelf holding a single video still fills both tiles.
    /// Shorts are skipped: the Top Shelf draws its tiles wide, with the title beside the artwork,
    /// which is neither the shape nor the metadata a Short has.
    private func updateTopShelf(from sections: [FeedSection]) {
        let candidates = sections.filter { !$0.isShorts }.flatMap(\.items)
        let videos = candidates.prefix(TopShelfStore.itemCount).map {
            TopShelfVideo(
                id: $0.id, title: $0.title, author: $0.author, thumbnailURL: $0.thumbnailURL)
        }
        TopShelfStore.save(Array(videos))
        // tvOS caches what the provider last returned and would otherwise keep showing it until
        // it next decides to ask. This is what makes the tiles follow a profile switch.
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    /// Drops shelves whose videos are all already on screen — YouTube repeats rows across pages.
    private func newSections(in candidates: [FeedSection]) -> [FeedSection] {
        let shown = Set(sections.flatMap { $0.items.map(\.id) })
        return candidates.filter { section in
            !section.items.allSatisfy { shown.contains($0.id) }
        }
    }

}

// MARK: - Row layout

/// How the fetched feeds are laid out down the screen.
///
/// Home arrives as one ordered list of shelves but isn't drawn as one: the subscriptions row is
/// dealt into it, directly under the recommendations. So the screen is four slots — Home's lead,
/// Subscriptions, the rest of Home, History — and these are what carve them out.
extension HomeView {

    /// The feeds fetched alongside Home.
    static var supplementaryFeeds: [Feed] { Feed.allCases.filter { $0 != .home } }

    /// Every supplementary row, in feed order. For the checks that care about the feed as a
    /// whole rather than where its rows are drawn.
    var supplementarySections: [FeedSection] {
        Self.supplementaryFeeds.flatMap { feedSections[$0] ?? [] }
    }

    /// Home's opening rows: everything up to and including the first row that isn't Shorts.
    ///
    /// That row is YouTube's recommendations. Nothing in the response marks it as such — a shelf
    /// carries only a title, which is localized and not ours — so it's identified by position,
    /// which is the one thing the response does state. The Shorts guard is the same one
    /// `FeedService.loadFeed` uses, and covers a response that opens with a Shorts row.
    var leadSections: ArraySlice<FeedSection> {
        guard let index = sections.firstIndex(where: { !$0.isShorts }) else { return sections[...] }
        return sections[...index]
    }

    /// The rest of Home, drawn below the subscriptions row. This is what paging grows.
    var trailingSections: ArraySlice<FeedSection> {
        sections[leadSections.endIndex...]
    }

    /// One of Home's rows. Home is drawn in two stretches with the subscriptions row between
    /// them, so both stretches build their rows through here.
    func homeRow(_ section: FeedSection) -> some View {
        FeedRow(
            section: section,
            onSelectVideo: onSelectVideo,
            onLongPressVideo: { menuItem = $0 },
            onNeedMoreItems: { prefetchItemsIfNeeded(in: section.id) },
            firstCardFocus: section.id == sections.first?.id ? $isFirstCardFocused : nil
        )
        .onAppear { prefetchIfNeeded(from: section) }
    }

    /// One row of a supplementary feed. Unlike Home's, these don't page the feed itself —
    /// only the row — so they carry no `onAppear`.
    func supplementaryRow(_ section: FeedSection) -> some View {
        FeedRow(
            section: section,
            onSelectVideo: onSelectVideo,
            onLongPressVideo: { menuItem = $0 },
            onNeedMoreItems: { prefetchItemsIfNeeded(in: section.id) }
        )
    }
}
