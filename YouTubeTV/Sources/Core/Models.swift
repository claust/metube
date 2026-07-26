import Foundation

/// A single video shown in the feed and passed to the player.
struct VideoItem: Identifiable, Hashable {
    let id: String          // YouTube videoId
    let title: String
    let author: String
    let thumbnailURL: URL?

    init(id: String, title: String, author: String = "", thumbnailURL: URL? = nil) {
        self.id = id
        self.title = title
        self.author = author
        self.thumbnailURL = thumbnailURL
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

    init(id: String = UUID().uuidString, title: String, items: [VideoItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
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
