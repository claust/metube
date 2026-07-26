import SwiftUI

/// The personalized Home feed: one horizontal, focusable row per YouTube shelf.
/// Selection is delegated to the orchestrator via `onSelectVideo`.
struct HomeView: View {
    /// Called when the user chooses a video. The orchestrator wires this to the player.
    var onSelectVideo: (VideoItem) -> Void

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

    /// A backstop on runaway paging — home is effectively endless, and each page costs a
    /// request plus a screenful of thumbnails.
    private static let maxPages = 8

    /// Start fetching the next page once a row this close to the end comes into view.
    private static let prefetchDistance = 2

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
                HStack {
                    Text("Home")
                        .font(.system(size: 56, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button("Sign out") { authStore.logout() }
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, HomeMetrics.horizontalInset)
                .padding(.top, 20)

                if sections.isEmpty && extraSections.isEmpty {
                    Text("No recommendations found.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, HomeMetrics.horizontalInset)
                        .padding(.top, 40)
                } else {
                    ForEach(sections) { section in
                        FeedRow(section: section, onSelectVideo: onSelectVideo)
                            .onAppear { prefetchIfNeeded(from: section) }
                    }

                    // Sits between Home and the supplementary feeds, where the next page lands.
                    if isLoadingMore {
                        ProgressView()
                            .tint(.white)
                            .padding(.horizontal, HomeMetrics.horizontalInset)
                    }

                    ForEach(extraSections) { section in
                        FeedRow(section: section, onSelectVideo: onSelectVideo)
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
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            guard let page = try await fetch({ try await FeedService().loadHome(accessToken: $0) }) else {
                return  // cancelled or signed out — nothing to show and nothing to report
            }
            sections = page.sections
            continuation = page.continuation
            pagesLoaded = 1
        } catch {
            if Task.isCancelled { return }
            errorMessage = error.localizedDescription
            return
        }

        // Home succeeded, so the token is known good — the supplementary feeds can use it
        // directly without repeating the refresh dance.
        if let token = authStore.accessToken {
            await loadSupplementaryFeeds(accessToken: token)
        }
    }

    /// Fetches Subscriptions and History concurrently and appends them below Home.
    /// Each feed degrades on its own: one failing leaves the others (and Home) intact.
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
            for await (feed, sections) in group { loaded[feed] = sections }
        }

        guard !Task.isCancelled else { return }
        // Present them in declared order, not in whichever order the requests finished.
        extraSections = feeds.flatMap { loaded[$0] ?? [] }
    }

    /// In a LazyVStack this runs as a row scrolls into view. Paging starts while there are
    /// still rows below, so reaching the bottom doesn't stall on a network round-trip —
    /// waiting for the genuinely last row would make the delay visible every time.
    private func prefetchIfNeeded(from section: FeedSection) {
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
                let page = try await fetch({
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
            if Task.isCancelled { return }
            // A failed page shouldn't wipe out the feed already on screen. Give up on paging
            // and leave what's loaded intact.
            continuation = nil
        }
    }

    /// Drops shelves whose videos are all already on screen — YouTube repeats rows across pages.
    private func newSections(in candidates: [FeedSection]) -> [FeedSection] {
        let shown = Set(sections.flatMap { $0.items.map(\.id) })
        return candidates.filter { section in
            !section.items.allSatisfy { shown.contains($0.id) }
        }
    }

    /// Runs a feed request, refreshing the access token once on a 401/403 and retrying.
    /// Returns `nil` when the work was cancelled or the refresh failed (which signs the user
    /// out — `AuthStore.refresh()` clears the tokens and RootView returns to the Login screen).
    @MainActor
    private func fetch<T>(_ request: (String) async throws -> T) async throws -> T? {
        guard let token = authStore.accessToken else { return nil }
        do {
            return try await request(token)
        } catch {
            // The view was dismissed while loading (cancellation surfaces as CancellationError
            // or URLError.cancelled) — not a real error.
            if Task.isCancelled { return nil }
            guard isAuthError(error) else { throw error }
            guard await authStore.refresh(), let newToken = authStore.accessToken else {
                return nil  // logged out — the router will show Login
            }
            return try await request(newToken)
        }
    }

    /// An expired/invalid access token surfaces as a 401/403 from InnerTube.
    private func isAuthError(_ error: Error) -> Bool {
        guard let inner = error as? InnerTubeError, case .badResponse(let code) = inner else {
            return false
        }
        return code == 401 || code == 403
    }
}

private enum HomeMetrics {
    /// Matches the tvOS title-safe inset used by the header and every row.
    static let horizontalInset: CGFloat = 80
    static let cardWidth: CGFloat = 420
    static let cardSpacing: CGFloat = 48
}

/// One shelf: a heading above a horizontally scrolling strip of cards.
private struct FeedRow: View {
    let section: FeedSection
    var onSelectVideo: (VideoItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !section.title.isEmpty {
                Text(section.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, HomeMetrics.horizontalInset)
            }

            ScrollView(.horizontal) {
                LazyHStack(spacing: HomeMetrics.cardSpacing) {
                    ForEach(section.items) { item in
                        VideoCard(item: item) { onSelectVideo(item) }
                            .frame(width: HomeMetrics.cardWidth)
                    }
                }
                .padding(.horizontal, HomeMetrics.horizontalInset)
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

/// A single focusable video thumbnail card.
private struct VideoCard: View {
    let item: VideoItem
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                AsyncImage(url: item.thumbnailURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .empty:
                        ZStack {
                            Color.gray.opacity(0.25)
                            ProgressView().tint(.white)
                        }
                    case .failure:
                        ZStack {
                            Color.gray.opacity(0.25)
                            Image(systemName: "play.rectangle")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                    @unknown default:
                        Color.gray.opacity(0.25)
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white, lineWidth: isFocused ? 4 : 0)
                )

                Text(item.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if !item.author.isEmpty {
                    Text(item.author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.08 : 1.0)
        .shadow(color: .black.opacity(isFocused ? 0.6 : 0), radius: 20)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}
