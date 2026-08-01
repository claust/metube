import Foundation

/// A news outlet the banner pulls headlines from.
///
/// One case for now. The banner shows whatever `NewsService` returns for the sources it is
/// given, so adding an outlet is a case plus its feed URL — nothing else in the app knows the
/// list. Feeds are plain RSS 2.0, which is the only shape `RSSFeedParser` reads.
enum NewsSource: String, CaseIterable, Identifiable, Hashable {
    case bbc

    var id: String { rawValue }

    /// Shown on the badge at the left of the banner, so a headline is always attributable
    /// even mid-scroll.
    var displayName: String {
        switch self {
        case .bbc: return "BBC NEWS"
        }
    }

    /// The outlet's front-page RSS feed. BBC publishes these openly for reuse under the terms
    /// linked from the feed's own `<copyright>`; they carry headline, one-line summary, a
    /// thumbnail and the article link — everything the banner needs and nothing more.
    var feedURL: URL {
        switch self {
        case .bbc: return URL(string: "https://feeds.bbci.co.uk/news/rss.xml")!
        }
    }
}

/// One headline, as it arrives from an RSS feed.
///
/// Deliberately close to the wire format: RSS gives a title, a sentence of summary, a link and
/// (on BBC) a small thumbnail — there is no article body in the feed, so anything wanting the
/// full text has to fetch the page itself.
struct NewsItem: Identifiable, Hashable {
    /// The feed's `<guid>`, which BBC makes unique per article. Falls back to the link when a
    /// feed omits it.
    let id: String
    let source: NewsSource
    let title: String
    /// The feed's `<description>` — a single sentence of standfirst, not the article.
    let summary: String
    let link: URL?
    /// The `<media:thumbnail>` BBC attaches, at whatever size the feed chose (240px wide today).
    let imageURL: URL?
    let publishedAt: Date?

    /// The same picture at a size worth showing full-screen.
    ///
    /// BBC's image CDN encodes the rendered width in the path (`/ace/standard/240/…`), so the
    /// larger variant is the same URL with a bigger number — there is no API for this, it is
    /// just how the paths are built. Any URL that doesn't match that shape is returned
    /// untouched, which is the right answer for a future source with a different CDN.
    var largeImageURL: URL? {
        guard let imageURL else { return nil }
        let text = imageURL.absoluteString
        guard let range = text.range(of: "/standard/240/") else { return imageURL }
        return URL(string: text.replacingCharacters(in: range, with: "/standard/1024/")) ?? imageURL
    }
}
