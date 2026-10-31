import Foundation

/// A news outlet the banner pulls headlines from.
///
/// The banner shows whatever `NewsService` returns for the sources it is given, so adding an
/// outlet is a case plus its feed URL — and, for the reading panel, a way to find the article
/// text on its pages (see `ArticleService`).
enum NewsSource: String, CaseIterable, Identifiable, Hashable {
    case bbc
    case dr

    var id: String { rawValue }

    /// Shown on the badge at the left of the banner, so a headline is always attributable
    /// even mid-scroll.
    var displayName: String {
        switch self {
        case .bbc: return "BBC NEWS"
        case .dr: return "DR NYHEDER"
        }
    }

    /// Where the outlet's headlines are read from.
    ///
    /// BBC's front-page RSS feed, published openly for reuse under the terms linked from its own
    /// `<copyright>`: headline, one-line summary, a thumbnail and the article link.
    ///
    /// DR's "Seneste nyt" page rather than any of its RSS feeds. The feed that sounds like it —
    /// `allenyheder` — is only DR's "Kort nyt" briefs plus sport, mostly without pictures, so
    /// the banner showed a different set of stories from the page people know. The page is the
    /// real timeline across every section, and embeds it as data with a picture per story.
    var feedURL: URL {
        switch self {
        case .bbc: return URL(string: "https://feeds.bbci.co.uk/news/rss.xml")!
        case .dr: return URL(string: "https://www.dr.dk/nyheder/seneste")!
        }
    }

    /// The first path segment of the outlet's sport pages. Neither feed carries a `<category>`,
    /// but both file every story under its section, so the link says what the story is about.
    private var sportSection: String {
        switch self {
        case .bbc: return "sport"
        case .dr: return "sporten"
        }
    }

    /// Whether a story's link is to the outlet's sport section — kept off the banner, which is
    /// for the news.
    func isSport(_ link: URL?) -> Bool {
        link?.pathComponents.dropFirst().first == sportSection
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
