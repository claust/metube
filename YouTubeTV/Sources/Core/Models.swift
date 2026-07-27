import Foundation

/// A single video shown in the feed and passed to the player.
struct VideoItem: Identifiable, Hashable {
    let id: String  // YouTube videoId
    let title: String
    let author: String
    let thumbnailURL: URL?
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

    init(
        id: String, title: String, author: String = "", thumbnailURL: URL? = nil,
        publishedAt: Date? = nil, viewCount: String = "", duration: String = ""
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.thumbnailURL = thumbnailURL
        self.publishedAt = publishedAt
        self.viewCount = viewCount
        self.duration = duration
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

    init(
        id: String = UUID().uuidString, title: String, items: [VideoItem],
        continuation: String? = nil
    ) {
        self.id = id
        self.title = title
        self.items = items
        self.continuation = continuation
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
}

/// One page of the feed: its shelves plus the token that fetches the next page, if any.
struct FeedPage {
    let sections: [FeedSection]
    /// `nil` when YouTube has no more pages to give.
    let continuation: String?
}
