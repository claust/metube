import Foundation
import SwiftUI

/// The personalized Home feed: one horizontal, focusable row per YouTube shelf.
/// Selection is delegated to the orchestrator via `onSelectVideo`.
struct HomeView: View {
    /// Called when the user chooses a video. The orchestrator wires this to the player.
    var onSelectVideo: (VideoItem) -> Void
    /// Called when the user picks the search icon. The orchestrator wires this to `SearchView`.
    var onOpenSearch: () -> Void

    @EnvironmentObject private var authStore: AuthStore

    @State private var sections: [FeedSection] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    /// Rows from the supplementary feeds (Subscriptions, History). Kept separate from `sections`
    /// so they stay pinned below Home as it pages, rather than being pushed around by it.
    @State private var extraSections: [FeedSection] = []

    /// Token for the next page of shelves; `nil` once the feed is exhausted or paging has stopped.
    @State private var continuation: String?
    @State private var isLoadingMore = false
    @State private var pagesLoaded = 0

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

    /// Start fetching more videos for a row once a card this close to its end comes into view.
    /// `FeedRow` below applies it, hence `fileprivate`.
    fileprivate static let itemPrefetchDistance = 4

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            content
        }
        .task {
            // Load once on first appear.
            if sections.isEmpty && !isLoading {
                await load()
            }
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
                HStack(spacing: 24) {
                    Text("Home")
                        .font(.system(size: 56, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button(action: onOpenSearch) {
                        Image(systemName: "magnifyingglass")
                            .font(.title2.weight(.semibold))
                    }
                    // The glyph carries no text, so name it for VoiceOver and the UI tests.
                    .accessibilityLabel("Search")
                    Button("Sign out") { authStore.logout() }
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, Metrics.horizontalInset)
                .padding(.top, 20)
                // Keeps left/right presses inside the header instead of dropping into the
                // first row, which sits directly beneath it.
                .focusSection()

                if sections.isEmpty && extraSections.isEmpty {
                    Text("No recommendations found.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Metrics.horizontalInset)
                        .padding(.top, 40)
                } else {
                    ForEach(sections) { section in
                        FeedRow(
                            section: section, onSelectVideo: onSelectVideo,
                            onNeedMoreItems: { prefetchItemsIfNeeded(in: section) }
                        )
                        .onAppear { prefetchIfNeeded(from: section) }
                    }

                    // Sits between Home and the supplementary feeds, where the next page lands.
                    if isLoadingMore {
                        ProgressView()
                            .tint(.white)
                            .padding(.horizontal, Metrics.horizontalInset)
                    }

                    ForEach(extraSections) { section in
                        FeedRow(
                            section: section, onSelectVideo: onSelectVideo,
                            onNeedMoreItems: { prefetchItemsIfNeeded(in: section) }
                        )
                    }
                }
            }
            .padding(.vertical, 60)
        }
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

    @MainActor
    private func load() async {
        guard authStore.accessToken != nil else {
            errorMessage = "You're not signed in."
            return
        }
        guard await loadHomeFirstPage() else { return }

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
            return true
        } catch {
            if isCancellation(error) { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Fetches Subscriptions and History concurrently and appends them below Home.
    /// Each feed degrades on its own: one failing or being slow leaves the others (and Home)
    /// unaffected, because rows are published as each feed arrives rather than in one batch.
    @MainActor
    private func loadSupplementaryFeeds(accessToken: String) async {
        let feeds = Feed.allCases.filter { $0 != .home }

        var loaded: [Feed: [FeedSection]] = [:]
        await withTaskGroup(of: (Feed, [FeedSection]).self) { group in
            for feed in feeds {
                group.addTask {
                    let page = try? await FeedService().loadFeed(feed, accessToken: accessToken)
                    return (feed, page?.sections ?? [])
                }
            }
            for await (feed, sections) in group {
                guard !Task.isCancelled else { return }
                loaded[feed] = sections
                // Rebuild from `feeds` rather than appending, so rows land in declared order
                // however the requests finish. A feed still pending contributes nothing yet.
                extraSections = feeds.flatMap { loaded[$0] ?? [] }
            }
        }
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
    private func prefetchItemsIfNeeded(in section: FeedSection) {
        guard section.continuation != nil, !rowsLoadingMore.contains(section.id) else { return }
        guard (rowPagesLoaded[section.id] ?? 1) < Self.maxRowPages else { return }
        Task { await loadMoreItems(in: section.id) }
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

            rowPagesLoaded[id, default: 1] += 1
            append(page.items, continuation: page.continuation, to: id)
        } catch {
            if isCancellation(error) { return }
            // Keep what's already in the row and stop paging it; the rest of the feed is fine.
            append([], continuation: nil, to: id)
        }
    }

    private func section(withID id: String) -> FeedSection? {
        sections.first { $0.id == id } ?? extraSections.first { $0.id == id }
    }

    /// Adds videos to the row with this id, in whichever list holds it.
    @MainActor
    private func append(_ items: [VideoItem], continuation: String?, to id: String) {
        func update(_ list: inout [FeedSection]) -> Bool {
            guard let index = list.firstIndex(where: { $0.id == id }) else { return false }
            let existing = Set(list[index].items.map(\.id))
            let fresh = items.filter { !existing.contains($0.id) }
            list[index] = FeedSection(
                id: id,
                title: list[index].title,
                items: list[index].items + fresh,
                // A page that adds nothing new means the row is going in circles: stop, or the
                // last card stays the trigger and refires on every scroll.
                continuation: fresh.isEmpty ? nil : continuation
            )
            return true
        }
        if update(&sections) { return }
        _ = update(&extraSections)
    }

    /// Drops shelves whose videos are all already on screen — YouTube repeats rows across pages.
    private func newSections(in candidates: [FeedSection]) -> [FeedSection] {
        let shown = Set(sections.flatMap { $0.items.map(\.id) })
        return candidates.filter { section in
            !section.items.allSatisfy { shown.contains($0.id) }
        }
    }

}

/// One shelf: a heading above a horizontally scrolling strip of cards.
private struct FeedRow: View {
    let section: FeedSection
    var onSelectVideo: (VideoItem) -> Void
    /// Fired as one of the last cards comes into view, so the row can grow before focus
    /// reaches its end.
    var onNeedMoreItems: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !section.title.isEmpty {
                Text(section.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Metrics.horizontalInset)
            }

            ScrollView(.horizontal) {
                LazyHStack(spacing: Metrics.cardSpacing) {
                    ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                        VideoCard(item: item) { onSelectVideo(item) }
                            // In a LazyHStack this runs as the card scrolls in, which is the
                            // point: paging starts while cards are still to the right of it.
                            .onAppear {
                                if index >= section.items.count - HomeView.itemPrefetchDistance {
                                    onNeedMoreItems()
                                }
                            }
                    }
                }
                .padding(.horizontal, Metrics.horizontalInset)
                // Room for the focused card to grow without colliding with the heading above.
                .padding(.vertical, 32)
            }
            // Without this the focus scale/shadow is cut off at the scroll view's edges.
            .scrollClipDisabled()
        }
        // Keeps left/right movement inside this row instead of jumping to a neighbouring one.
        .focusSection()
    }
}
