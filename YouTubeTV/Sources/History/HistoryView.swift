import SwiftUI

/// The menu's History screen: what has already been watched, most recent first, as a grid of the
/// same cards the feed draws — press one and it resumes where it was left.
///
/// The list is built from `WatchProgressStore`, which is the app's real record of what has been
/// watched: a position, a duration and a date per video, written by the player, synced to the
/// backend and restored on a fresh install or a second Apple TV. It is also why the cards here
/// carry the red progress line that the same videos have anywhere else in the app — the page is
/// drawn from the very thing that line comes from.
///
/// What that record does *not* hold is the videos themselves. `WatchHistoryStore` is the other
/// half: a card per video, filled in from the player, from the account's history list, and by
/// looking up whatever ids are left (see `VideoMetadataService`).
///
/// Folded into the same list is the account's own history from YouTube (`FEhistory`, ~15 videos,
/// no paging) — the only sight we get of what was watched on a phone or a laptop, since nothing
/// played here ever reaches it. It carries no timestamps, only YouTube's ordering, so those
/// videos are placed rather than dated; see `watchTimes`.
struct HistoryView: View {
    /// Bumped by the shell when the menu picks this section. The page answers by taking focus,
    /// which is what closes the menu behind the press — the same handshake Home does.
    var focusRequest: Int = 0

    /// Opens a video. The shell wires this to the same player Home and Search present.
    var onSelectVideo: (VideoItem) -> Void

    /// Called when a card's menu picks "Go to channel", wired by the shell to `ChannelView`.
    var onOpenChannel: (VideoItem) -> Void

    @EnvironmentObject private var authStore: AuthStore
    @EnvironmentObject private var watchProgress: WatchProgressStore
    @EnvironmentObject private var history: WatchHistoryStore

    /// The account's own history, as YouTube ordered it. Fetched on arrival — it is a screen the
    /// user has to go looking for, so one request per visit is cheap, and it is the only way to
    /// notice what was watched on another client since.
    @State private var accountItems: [VideoItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    /// The card whose menu is open, and `nil` when none is. Held here rather than in the card so
    /// one dialog serves the whole page, exactly as on Home.
    @State private var menuItem: VideoItem?

    /// What focus can be on. The header is a target in its own right so that the empty, loading
    /// and failed screens — none of which have a card — still have somewhere to put focus:
    /// without one, arriving here would leave the focus engine holding nothing and the menu would
    /// never close.
    private enum Target: Hashable {
        case page
        case video(String)
    }

    @FocusState private var focus: Target?

    /// Four across, which is the shape this screen was prototyped in.
    private static let columns = 4
    private static let columnSpacing: CGFloat = 40
    private static let rowSpacing: CGFloat = 48

    /// How far back the page goes. Watch progress is unbounded and years of it would be a
    /// thousand thumbnails and a lookup apiece; this is around fifty rows, which is further back
    /// than anyone scrolls.
    private static let maxRows = 200

    /// How many lookups run at once. The rest of the app makes one request at a time per screen;
    /// this is the one place with a queue of them, and four keeps a first visit brisk without
    /// opening a connection per video in the history.
    private static let lookupConcurrency = 4

    /// How wide the page's content is, measured rather than assumed: what is left of the screen
    /// here is the canvas minus the menu's rail minus the title-safe inset, and a card drawn at
    /// the feed's own width overflows its column by enough to butt into its neighbour.
    @State private var contentWidth: CGFloat = 0

    /// One column, and so the width each card is drawn at. Falls back to the feed's card width
    /// for the one layout pass before the measurement lands.
    private var cardWidth: CGFloat {
        guard contentWidth > 0 else { return Metrics.cardWidth }
        let count = CGFloat(Self.columns)
        return ((contentWidth - Self.columnSpacing * (count - 1)) / count).rounded(.down)
    }

    /// When each video was watched — one list, however the app came to know about it.
    ///
    /// Three sources, in order of how much they actually know:
    ///
    ///  - watch progress, whose date is the real thing: the moment the player last wrote a
    ///    position, on this box or any other;
    ///  - videos played here too briefly to record a position, which the card store dates;
    ///  - the account's history list, which carries no times at all — only YouTube's ordering.
    ///
    /// That last group has to be *placed* rather than dated, and the rule is to claim as little
    /// as the evidence allows: an undated video sits directly below the most recent video we do
    /// have a time for, in the order YouTube listed it. So it never jumps above something we know
    /// is newer, and a run of them stays in YouTube's sequence. A second apiece is arbitrary —
    /// it's a sort key, not a claim about when anything happened.
    private func watchTimes() -> [String: Date] {
        var when: [String: Date] = [:]
        for (id, entry) in watchProgress.entries { when[id] = entry.updatedAt }
        for (id, watchedAt) in history.watchedHere where (when[id] ?? .distantPast) < watchedAt {
            when[id] = watchedAt
        }

        var anchor = when.values.max() ?? .now
        for item in accountItems {
            // A video YouTube lists that we *do* know the time of re-anchors the run below it —
            // which is what keeps a long account list from drifting up past older watches.
            if let known = when[item.id] {
                anchor = known
                continue
            }
            anchor = anchor.addingTimeInterval(-1)
            when[item.id] = anchor
        }
        return when
    }

    /// Everything watched, newest first. A card the store hasn't got yet is drawn from its id and
    /// filled in when its lookup lands — see `resolveMissingCards`.
    private var watched: [VideoItem] {
        watchTimes()
            .sorted { $0.value > $1.value }
            .prefix(Self.maxRows)
            .map { id, _ in history.card(for: id) ?? Self.placeholder(id: id) }
    }

    /// The first card on the page, for the handoff from the menu.
    private var firstVideoID: String? { watched.first?.id }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                header

                content
                    .padding(.top, 56)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Measured inside the inset, so this is exactly the width the grid has to fill.
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onChange(of: proxy.size.width, initial: true) { _, width in
                            contentWidth = width
                        }
                }
            }
            .padding(.horizontal, Metrics.horizontalInset)
            .padding(.vertical, 80)
        }
        // The page is one focus region and the menu is another, so a press up from a card finds
        // the row above rather than stepping out sideways into the menu.
        .focusSection()
        .videoMenu(for: $menuItem, onOpenChannel: onOpenChannel)
        // Ordered, not raced: the account's history arrives as ~15 finished cards, and every one
        // of them is a video the lookups below would otherwise spend a request on.
        .task {
            await loadAccountHistory()
            await resolveMissingCards()
        }
        // The same delay the feed's handoffs need: the page has to be on screen before there is
        // anything to put focus on.
        .task(id: focusRequest) {
            guard focusRequest > 0 else { return }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            focus = firstVideoID.map { .video($0) } ?? .page
        }
        // Focus landed on the header because there were no cards yet — a fresh install, where
        // everything on this page comes from the account request still in flight. Hand it to the
        // first card now that there is one, but never off a card the user has since moved to.
        .onChange(of: firstVideoID) { _, first in
            guard focus == .page, let first else { return }
            focus = .video(first)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("History")
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(.white)

            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.white.opacity(0.5))
        }
        // Focusable so the screens with no cards still have a home for focus; see `Target`.
        .focusable()
        .focused($focus, equals: .page)
    }

    private var subtitle: String {
        let count = watched.count
        if count == 0 {
            if isLoading { return "Looking up what you've watched…" }
            if errorMessage != nil { return "Couldn't reach your account." }
            return "Nothing watched yet."
        }
        return count == 1 ? "1 video, most recent first" : "\(count) videos, most recent first"
    }

    @ViewBuilder
    private var content: some View {
        if !watched.isEmpty {
            grid(watched)
        } else if isLoading {
            ProgressView()
                .tint(.white)
        } else if let errorMessage {
            failure(errorMessage)
        } else {
            Text("Play something and it will show up here.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private func grid(_ items: [VideoItem]) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(
                    .fixed(cardWidth), spacing: Self.columnSpacing, alignment: .topLeading),
                count: Self.columns),
            spacing: Self.rowSpacing
        ) {
            ForEach(items) { item in
                VideoCard(
                    item: item,
                    width: cardWidth,
                    onLongPress: { menuItem = item },
                    action: { onSelectVideo(item) }
                )
                .focused($focus, equals: .video(item.id))
            }
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
            Button("Try again") {
                Task { await loadAccountHistory() }
            }
            .font(.headline)
        }
    }

    /// A card for a video nothing has ever described: its artwork, which needs no request, and
    /// no words until its lookup lands.
    private static func placeholder(id: String) -> VideoItem {
        VideoItem(id: id, title: "", thumbnailURL: VideoItem.artworkURL(videoId: id))
    }

    // MARK: - Loading

    /// Fetches the account's own history: the videos watched on the account's other clients, and
    /// fifteen finished cards for one request — several of which the page would otherwise have to
    /// look up one at a time.
    ///
    /// Failure only reaches the screen when there is nothing else on it — a page already showing
    /// what has been watched shouldn't turn into an error because this didn't arrive.
    @MainActor
    private func loadAccountHistory() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let page = try await authStore.authorized { token in
                try await FeedService().loadFeed(.history, accessToken: token)
            }
            // `nil` means nobody is signed in, or the load was called off — neither of which is
            // an empty history, and the empty copy would be the screen answering a question it
            // never got an answer to. A cancelled load needs no message: the screen is being left.
            guard let page else {
                if !Task.isCancelled, watched.isEmpty {
                    errorMessage = "Your account couldn't be reached."
                }
                return
            }
            // YouTube repeats a video across the shelves it chunks the list into, and two cards
            // for one video would be two grid cells with the same identity.
            var seen = Set<String>()
            accountItems = page.sections.flatMap(\.items).filter { seen.insert($0.id).inserted }
            history.remember(accountItems)
        } catch {
            // A cancelled load is the screen being left, not a failure to report.
            if isCancellation(error) { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Looks up the videos on this page that nothing has ever described — the watch progress
    /// restored from the backend, mostly, which is ids and dates and nothing else.
    ///
    /// In display order, a few at a time, and only once per visit: an answer is kept for good
    /// (see `WatchHistoryStore`), so this is a cost the first visit after a fresh install pays
    /// and later ones don't. Videos that come back with nothing — deleted, private — are simply
    /// left as they are; retrying them on every visit would be a request per visit forever, and
    /// what they'd return is already known.
    @MainActor
    private func resolveMissingCards() async {
        let missing = watched.filter { $0.title.isEmpty }.map(\.id)
        guard !missing.isEmpty else { return }

        let service = VideoMetadataService()
        var index = 0
        await withTaskGroup(of: VideoItem?.self) { group in
            func addTask() {
                guard index < missing.count else { return }
                let videoId = missing[index]
                index += 1
                group.addTask { try? await service.load(videoId: videoId) }
            }

            for _ in 0..<Self.lookupConcurrency { addTask() }
            while let item = await group.next() {
                guard !Task.isCancelled else { return group.cancelAll() }
                // Applied one at a time rather than in a batch at the end: the page fills in as
                // the answers arrive, and a visit cut short still keeps whatever landed.
                if let item { history.remember([item]) }
                addTask()
            }
        }
        // Whatever is on the page now is what the cards are for; anything else in the store is a
        // video that has since fallen off the end of the history.
        history.prune(keeping: Set(watched.map(\.id)).union(accountItems.map(\.id)))
    }
}
