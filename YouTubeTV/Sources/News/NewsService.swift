import Foundation

/// Fetches headlines from the news sources' RSS feeds.
///
/// No credentials and no InnerTube: these are public feeds fetched with a plain GET, which is
/// why this sits apart from the YouTube services and why the banner works signed out.
struct NewsService {
    /// How many headlines to keep per source. A front-page feed carries a few dozen; the
    /// banner is a glance-at-it strip, and a lap the length of a full feed takes minutes to
    /// come round.
    static let itemsPerSource = 12

    /// Headlines from every given source, newest first, interleaved by publication date.
    ///
    /// A source that fails is dropped rather than failing the whole banner — with one outlet
    /// that means an empty banner, but the moment there are two, one being down must not take
    /// the other's headlines off screen with it.
    func headlines(from sources: [NewsSource] = NewsSource.allCases) async -> [NewsItem] {
        var collected: [NewsItem] = []
        await withTaskGroup(of: [NewsItem].self) { group in
            for source in sources {
                group.addTask { (try? await self.headlines(from: source)) ?? [] }
            }
            for await items in group {
                collected.append(contentsOf: items)
            }
        }
        // Undated items sort last: a feed that gave no `pubDate` said nothing about how fresh
        // it is, and guessing "now" would put it in front of everything that did.
        return collected.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
    }

    /// Headlines from a single source.
    func headlines(from source: NewsSource) async throws -> [NewsItem] {
        var request = URLRequest(url: source.feedURL)
        // The feed is refetched on a schedule, and a cached body is exactly as good as a fresh
        // one within the feed's own `<ttl>`. Left on the default policy so URLSession honours it.
        request.setValue("application/rss+xml, application/xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NewsError.feedUnavailable(source)
        }
        let items = RSSFeedParser(source: source).parse(data)
        return Array(items.prefix(Self.itemsPerSource))
    }
}

enum NewsError: LocalizedError {
    case feedUnavailable(NewsSource)

    var errorDescription: String? {
        switch self {
        case .feedUnavailable(let source):
            return "Couldn't reach the \(source.displayName) feed."
        }
    }
}

/// Reads RSS 2.0 into `NewsItem`s.
///
/// A hand-rolled `XMLParser` delegate rather than a dependency: the feed is four elements deep
/// and this is the whole of it. Text arrives as CDATA in BBC's feed and as plain characters in
/// others, so both callbacks append to the same buffer.
private final class RSSFeedParser: NSObject, XMLParserDelegate {
    private let source: NewsSource

    /// The `<item>` being read, filled element by element and flushed on `</item>`.
    private var current: Fields?
    /// Text seen since the last start tag. Reset by `didStartElement`, consumed by `didEndElement`.
    private var buffer = ""
    private var items: [NewsItem] = []

    /// The raw strings of one `<item>`, before they are turned into a `NewsItem`.
    private struct Fields {
        var title = ""
        var description = ""
        var link = ""
        var guid = ""
        var pubDate = ""
        var imageURL = ""
    }

    /// RSS dates are RFC 822 ("Sat, 01 Aug 2026 05:42:31 GMT"). Fixed locale because the format
    /// has English month and day names regardless of where the device is.
    ///
    /// One per parser rather than one shared static: sources are fetched and parsed
    /// concurrently, and a formatter owned by the parse it belongs to is trivially confined to
    /// that task. `DateFormatter` is documented as thread-safe for parsing, so this isn't
    /// fixing a live race — it costs one object per fetch and removes the shared mutable state
    /// from the question entirely.
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    init(source: NewsSource) {
        self.source = source
    }

    func parse(_ data: Data) -> [NewsItem] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.parse()
        return items
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String]
    ) {
        buffer = ""
        switch elementName {
        case "item":
            current = Fields()
        case "media:thumbnail", "media:content":
            // The picture is an attribute on an empty element, so it is read here rather than
            // at the closing tag. Guarded on `current` because the channel-level `<image>`
            // block uses the same names in some feeds and is not this article's picture.
            if current != nil, let url = attributes["url"], current?.imageURL.isEmpty == true {
                current?.imageURL = url
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        // Non-UTF8 bytes in a CDATA block are dropped rather than mangled — a headline that
        // arrives undecodable is better skipped than shown as replacement characters.
        guard let text = String(bytes: CDATABlock, encoding: .utf8) else { return }
        buffer += text
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName: String?
    ) {
        defer { buffer = "" }
        guard current != nil else { return }
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "title": current?.title = text
        case "description": current?.description = text
        case "link": current?.link = text
        case "guid": current?.guid = text
        case "pubDate": current?.pubDate = text
        case "item":
            if let fields = current, let item = makeItem(from: fields) { items.append(item) }
            current = nil
        default:
            break
        }
    }

    /// Builds an item, or `nil` for an entry with no headline — there is nothing to show for it.
    private func makeItem(from fields: Fields) -> NewsItem? {
        guard !fields.title.isEmpty else { return nil }
        let id = fields.guid.isEmpty ? fields.link : fields.guid
        guard !id.isEmpty else { return nil }
        return NewsItem(
            id: id,
            source: source,
            title: fields.title,
            summary: fields.description,
            link: URL(string: fields.link),
            imageURL: URL(string: fields.imageURL),
            publishedAt: dateFormatter.date(from: fields.pubDate)
        )
    }
}
