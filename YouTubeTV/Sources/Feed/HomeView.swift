import Foundation
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
            guard let page = try await fetch({ try await FeedService().loadHome(accessToken: $0) }) else {
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
            if isCancellation(error) { return }
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
            // The view was dismissed while loading — not a real error.
            if isCancellation(error) { return nil }
            guard isAuthError(error) else { throw error }
            guard await authStore.refresh(), let newToken = authStore.accessToken else {
                return nil  // logged out — the router will show Login
            }
            return try await request(newToken)
        }
    }

    /// True when an error only means the work was cancelled — typically the view being
    /// dismissed mid-load. `Task.isCancelled` alone isn't enough: URLSession reports a
    /// cancelled request as `URLError.cancelled` (-999), which can surface without the
    /// enclosing Task being marked cancelled, and would otherwise show the error screen.
    private func isCancellation(_ error: Error) -> Bool {
        if Task.isCancelled || error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
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

    /// Shared by the focus panel and the thumbnail's top corners.
    private static let cornerRadius: CGFloat = 16

    var body: some View {
        Button(action: action) {
            // No spacing or outer padding: the thumbnail runs the full width of the focus
            // panel and butts against its top and side edges, so focusing genuinely enlarges
            // the image rather than framing it.
            VStack(alignment: .leading, spacing: 0) {
                // A 16:9 box the full width of the card, with the image laid over it and
                // cropped to fit. Sizing the AsyncImage itself instead would letterbox: the
                // thumbnails YouTube serves aren't all 16:9 (`hqdefault.jpg` is 4:3 with black
                // bars baked in), and a fitted image leaves the card's edges showing through.
                Color.gray.opacity(0.25)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay { thumbnail }
                    .overlay(alignment: .bottomTrailing) { channelBadge }
                    // Only the top corners are rounded — the bottom edge meets the caption,
                    // and matching the panel's radius keeps the two reading as one surface.
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: Self.cornerRadius,
                            topTrailingRadius: Self.cornerRadius,
                            style: .continuous
                        )
                    )

                caption
            }
            // Fix the width here rather than outside the button. A wrapping title reports an
            // ideal width far wider than the card, and an outer frame doesn't clamp it — the
            // caption spilled past the thumbnail and dragged the panel out with it.
            .frame(width: HomeMetrics.cardWidth)
            // The one focus surface: a soft grey panel behind the whole card, in place of the
            // white outline and the white plate that used to sit under the caption.
            .background(
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .fill(isFocused ? Color(white: 0.86) : Color.clear)
            )
        }
        .buttonStyle(BareButtonStyle())
        .focusEffectDisabled()
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.08 : 1.0)
        .shadow(color: .black.opacity(isFocused ? 0.6 : 0), radius: 20)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }

    /// The artwork itself. `scaledToFill` overflows the 16:9 box it sits in; the card's
    /// `clipShape` trims the overflow.
    @ViewBuilder
    private var thumbnail: some View {
        AsyncImage(url: item.thumbnailURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .empty:
                ProgressView().tint(.white)
            case .failure:
                Image(systemName: "play.rectangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            @unknown default:
                Color.clear
            }
        }
    }

    /// The channel, tucked into the corner of the thumbnail. Its own dark pill rather than bare
    /// text — thumbnails are arbitrary images, so nothing else guarantees contrast under it.
    @ViewBuilder
    private var channelBadge: some View {
        if !item.author.isEmpty {
            Text(item.author)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.black.opacity(0.65)))
                .padding(10)
        }
    }

    /// Title, then views and age on a line of their own. Text goes black on focus, against the
    /// grey panel behind the card — white-on-black beside a lit thumbnail is the hardest thing
    /// on the row to read.
    private var caption: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(isFocused ? .black : .white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if !stats.isEmpty {
                Text(stats)
                    .font(.caption)
                    .foregroundStyle(isFocused ? Color.black.opacity(0.6) : Color.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
        // Room for two title lines plus the stats line, so a short title doesn't shrink the
        // card below its neighbours and leave the row's focus panels ragged.
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    /// "1.2M views · 3 days ago · 21:55", dropping whichever parts the feed didn't supply.
    private var stats: String {
        let age = item.publishedAt.flatMap { RelativeTime.string(for: $0) } ?? ""
        return [item.viewCount, age, item.duration]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// Renders a button as nothing but its label.
///
/// Even `.plain` lifts a focused tvOS button onto a system platter — a padded surface, drawn
/// wider than the card, that also washes the content with a specular highlight. That platter
/// was the margin around the thumbnail. With this style the card's own grey panel is the whole
/// focus treatment, so the artwork reaches its edges.
private struct BareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
