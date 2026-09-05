import Foundation

/// A single video shown in the feed and passed to the player.
struct VideoItem: Identifiable, Hashable {
    let id: String  // YouTube videoId
    let title: String
    let author: String
    /// The channel's `UC…` id, when the cell carried one. What `ChannelAvatarStore` looks the
    /// channel's picture up by, and what the card's menu needs for both of its actions — a cell
    /// without one offers neither "Go to channel" nor the subscribe toggle.
    let channelID: String?
    let thumbnailURL: URL?
    /// The channel's round profile picture, when the cell carried one. Not every shelf sends it
    /// — the TV feed's tiles often don't — so anything drawing it must cope with `nil`.
    let channelAvatarURL: URL?
    /// When the video went up, approximated from InnerTube's "3 days ago" text at parse time
    /// (see `RelativeTime.parse`). `nil` when the feed gave no age — Shorts and some History
    /// rows don't.
    let publishedAt: Date?
    /// InnerTube's already-abbreviated view count ("1.2M views"), shown verbatim — it arrives
    /// as display text, never as a number. Empty when the feed didn't supply one.
    let viewCount: String
    /// Running time as InnerTube renders it on the thumbnail ("21:55", "1:02:14"). Empty for
    /// live streams and anything the feed didn't label.
    let duration: String
    /// Whether this is a Short rather than an ordinary video — see `VideoItemParser`'s
    /// detection. Shorts are drawn as portrait tiles and only ever shown in a Shorts row, so
    /// this decides both which section the item may appear in and how its card looks.
    /// `var` so a row known to be a Shorts row can vouch for items its cells didn't label
    /// (see `asShort()`).
    var isShort: Bool

    init(
        id: String, title: String, author: String = "", channelID: String? = nil,
        thumbnailURL: URL? = nil, channelAvatarURL: URL? = nil, publishedAt: Date? = nil,
        viewCount: String = "", duration: String = "", isShort: Bool = false
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.channelID = channelID
        self.thumbnailURL = thumbnailURL
        self.channelAvatarURL = channelAvatarURL
        self.publishedAt = publishedAt
        self.viewCount = viewCount
        self.duration = duration
        self.isShort = isShort
    }

    /// This item, marked as a Short.
    ///
    /// Used where the *row* is the evidence: the cells a Shorts shelf pages in don't always
    /// carry the reel endpoint or the portrait artwork their first-page siblings do, and a card
    /// that arrived in a Shorts row is a Short whatever its cell looked like.
    func asShort() -> VideoItem {
        var copy = self
        copy.isShort = true
        return copy
    }
}

extension VideoItem {
    /// `publishedAt` rounded to the minute, which is the finest a feed's ages can honestly be
    /// compared at.
    ///
    /// Each cell's age is parsed against its own `Date()` (see `VideoItemParser`), so two cards
    /// both reading "3 days ago" come out microseconds apart — in parse order, and the *later*
    /// one looks newer. Sorting on the raw dates would therefore reverse same-age videos rather
    /// than leave them be. Rounding folds that skew away without touching ages that genuinely
    /// differ: the shortest unit InnerTube's text ever carries is a second, and two uploads that
    /// land in one bucket are as good as simultaneous on a row of cards.
    ///
    /// A bucket rather than a tolerance, and deliberately so. "Within a minute of each other"
    /// isn't transitive — a is close to b, b to c, a not to c — so it isn't an ordering, and
    /// `sorted(by:)` requires one. The price of a bucket is a boundary: two timestamps under a
    /// minute apart do occasionally fall either side of it. That is true of any bucketing,
    /// whichever way it rounds, and the skew this exists to absorb is microseconds wide, so it
    /// takes a near-exact hit on the boundary to happen at all.
    var publishedMinute: TimeInterval? {
        publishedAt.map { ($0.timeIntervalSince1970 / 60).rounded() }
    }
}

extension Array where Element == VideoItem {
    /// This list newest first, as far as InnerTube's age text allows.
    ///
    /// Best effort by nature: the dates behind it are approximated from "3 days ago" strings, so
    /// everything published on the same day carries the same age and cannot be told apart. Those
    /// ties keep the order YouTube sent them in — the only further signal there is — which is why
    /// this sorts on the original index as a tiebreak rather than calling `sorted(by:)`, whose
    /// stability Swift promises nothing about.
    ///
    /// Items whose cell carried no age at all (Shorts, some History rows) sink to the end: there
    /// is nothing to place them by, and a guess would push dated videos out of order.
    func newestFirst() -> [VideoItem] {
        enumerated()
            .sorted { lhs, rhs in
                switch (lhs.element.publishedMinute, rhs.element.publishedMinute) {
                case let (left?, right?):
                    if left != right { return left > right }
                case (nil, .some):
                    return false
                case (.some, nil):
                    return true
                case (nil, nil):
                    break
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}

/// One horizontal row of the feed — a YouTube "shelf" such as Recommended or Watch it again.
struct FeedSection: Identifiable, Hashable {
    /// Assigned at parse time. Pages are only ever appended, so this stays stable for the
    /// lifetime of the feed — and unique across pages, which a title/index-derived id wouldn't be.
    let id: String
    /// The shelf heading. Empty when YouTube gave the shelf no title.
    let title: String
    let items: [VideoItem]
    /// Token that fetches more videos for *this row* (scrolling right). Separate from
    /// `FeedPage.continuation`, which fetches more rows. `nil` once the row is exhausted.
    let continuation: String?
    /// Whether this row holds Shorts. Shorts live in a row of their own — they're filtered out
    /// of every other one — so this is the one place they appear, and it's what tells the row
    /// to lay its cards out portrait.
    let isShorts: Bool

    init(
        id: String = UUID().uuidString, title: String, items: [VideoItem],
        continuation: String? = nil, isShorts: Bool = false
    ) {
        self.id = id
        self.title = title
        self.items = items
        self.continuation = continuation
        self.isShorts = isShorts
    }

    /// Items from this row's continuation, shaped to what this row shows: a Shorts row vouches
    /// for everything it pages in, and every other row drops the Shorts YouTube mixes into it.
    ///
    /// Applied where a page is appended rather than where it's fetched, because the row is the
    /// only thing that knows which of the two it is — a continuation reply is a bare list of
    /// cells with nothing naming the shelf it belongs to.
    func admitting(_ items: [VideoItem]) -> [VideoItem] {
        isShorts ? items.map { $0.asShort() } : items.filter { !$0.isShort }
    }
}

/// One page of a single row: the videos it added plus the token for the page after it.
struct FeedRowPage {
    let items: [VideoItem]
    /// `nil` when the row has no more videos.
    let continuation: String?
}

/// A browsable YouTube feed, identified by its InnerTube `browseId`.
enum Feed: CaseIterable {
    case home
    case subscriptions
    case history

    var browseId: String {
        switch self {
        case .home: return "default"
        case .subscriptions: return "FEsubscriptions"
        case .history: return "FEhistory"
        }
    }

    /// Heading for this feed's rows. Shelves inside a feed carry their own sub-title
    /// (Subscriptions groups by date, for example), so this names the feed itself.
    var title: String {
        switch self {
        case .home: return "Home"
        case .subscriptions: return "From your subscriptions"
        case .history: return "Continue watching"
        }
    }

    /// Whether this feed reads better newest-first than in the order YouTube sent it.
    ///
    /// Subscriptions is the one feed that is simply a list of what your channels have put up,
    /// and the question it answers is "what's new" — but the response opens on a relevance-ranked
    /// shelf (`Most relevant`), so the newest upload can sit anywhere in it. Home is
    /// recommendations, where the order *is* the recommendation, and History is the order things
    /// were watched in; reordering either would throw away the only thing their order says.
    var isChronological: Bool { self == .subscriptions }
}

/// A channel's browse page: who it is, and its shelves in the same shape as any feed's.
struct ChannelPage {
    /// The channel's name. Empty when the header didn't carry one, in which case the caller
    /// falls back to the name on the card the user came from.
    let title: String
    let avatarURL: URL?
    /// The channel's banner, already cropped to 16:9 by YouTube for TV clients, for drawing
    /// behind the header. `nil` when the channel has set no banner.
    let bannerURL: URL?
    /// Whether the account subscribes, per the page's own subscribe button. `nil` when the page
    /// carried no button — not the same as "no", so callers must leave their state alone.
    let isSubscribed: Bool?
    let feed: FeedPage
}

/// One page of the feed: its shelves plus the token that fetches the next page, if any.
struct FeedPage {
    let sections: [FeedSection]
    /// `nil` when YouTube has no more pages to give.
    let continuation: String?
    /// Channel name → avatar, for whatever channels this response happened to picture. Only the
    /// Subscriptions feed carries any; see `ChannelAvatarStore`.
    let channelAvatars: [String: URL]

    init(sections: [FeedSection], continuation: String?, channelAvatars: [String: URL] = [:]) {
        self.sections = sections
        self.continuation = continuation
        self.channelAvatars = channelAvatars
    }
}
