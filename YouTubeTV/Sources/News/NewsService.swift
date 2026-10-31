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
    /// A source that fails is dropped rather than failing the whole banner: one outlet being
    /// down must not take the other's headlines off screen with it.
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
        switch source {
        case .bbc:
            request.setValue("application/rss+xml, application/xml", forHTTPHeaderField: "Accept")
        case .dr:
            // A page, not a feed — and served whole only to a browser, like the article pages.
            request.setValue(ArticleService.userAgent, forHTTPHeaderField: "User-Agent")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NewsError.feedUnavailable(source)
        }
        let parsed: [NewsItem]
        switch source {
        case .bbc: parsed = RSSFeedParser(source: source).parse(data)
        case .dr: parsed = String(bytes: data, encoding: .utf8).map(DRLatestNewsParser.items) ?? []
        }
        // Sport is dropped before the cut rather than after, so an evening of match reports
        // doesn't leave an outlet with half its share of the banner.
        let items = parsed.filter { !source.isSport($0.link) }
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

    /// The elements whose text is kept. Anything else inside an `<item>` is markup we are
    /// passing through rather than a field, and must not disturb the buffer — see the two
    /// callbacks below.
    private static let capturedElements: Set<String> = [
        "title", "description", "link", "guid", "pubDate",
    ]

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
        switch elementName {
        case "item":
            current = Fields()
            buffer = ""
        case "media:thumbnail", "media:content":
            // The picture is an attribute on an empty element, so it is read here rather than
            // at the closing tag. Guarded on `current` because the channel-level `<image>`
            // block uses the same names in some feeds and is not this article's picture.
            if current != nil, let url = attributes["url"], current?.imageURL.isEmpty == true {
                current?.imageURL = url
            }
        default:
            // Only a field we capture starts a fresh buffer. A tag nested inside one — markup
            // in a `<description>` that the feed didn't wrap in CDATA, say — would otherwise
            // wipe the text accumulated so far and cut the field off at the first inner tag.
            if Self.capturedElements.contains(elementName) { buffer = "" }
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
        guard current != nil else {
            buffer = ""
            return
        }
        if elementName == "item" {
            if let fields = current, let item = makeItem(from: fields) { items.append(item) }
            current = nil
            buffer = ""
            return
        }
        // The closing half of the rule above: a nested tag ending must leave the enclosing
        // field's text where it is. Its own text has already been appended, so markup inside a
        // field comes through as the text with the tags dropped.
        guard Self.capturedElements.contains(elementName) else { return }

        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "title": current?.title = text
        case "description": current?.description = text
        case "link": current?.link = text
        case "guid": current?.guid = text
        case "pubDate": current?.pubDate = text
        default: break
        }
        buffer = ""
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

/// Reads DR's "Seneste nyt" page into `NewsItem`s.
///
/// The page is a Next.js app, and the list it renders arrives with it as data: a
/// `self.__next_f.push([1,"…"])` call whose string holds the page's component tree, in which
/// the `LatestNewsPage` component carries `"publications":[…]` — one `{"content":{…}}` per
/// story, newest first, with title, path, ISO start date, summary, section and teaser picture.
/// Read from there rather than from the rendered cards, whose times are "11 min. siden" and
/// whose pictures are buried in `srcset`s.
enum DRLatestNewsParser {
    private static let base = URL(string: "https://www.dr.dk")!

    /// Formats that are not something to read: a reel is a vertical video with a caption, and
    /// opening one in the reading panel would show nothing but its headline.
    private static let skippedFormats: Set<String> = ["ReelsFormat"]

    /// The teaser picture at a size worth showing in the reading panel. DR's image service takes
    /// the crop in the query string, and the bare URL in the data is the full-size original,
    /// several megabytes for a 430-point frame.
    ///
    /// Exactly the variant DR's own pages ask for on a high-resolution screen, query and all.
    /// The service renders each size the first time it is asked for — seconds, sometimes tens of
    /// them — and serves it in a tenth of a second after that, so a size the website has already
    /// asked for is often ready. One of our own invention never is.
    private static let pictureQuery = "im=SmartCrop%2Csize%3D%28960%2C540%29&impolicy=mediumlow"

    static func items(in html: String) -> [NewsItem] {
        guard let publications = publications(in: html) else { return [] }
        let dates = ISO8601DateFormatter()
        return publications.compactMap { entry in
            guard let content = entry["content"] as? [String: Any],
                let title = content["title"] as? String, !title.isEmpty,
                let path = content["urlPathId"] as? String,
                // Absolute for stories filed elsewhere on dr.dk (sport's live blogs), a path for
                // the rest.
                let link = URL(string: path, relativeTo: base)?.absoluteURL
            else { return nil }
            if let format = content["format"] as? String, skippedFormats.contains(format) {
                return nil
            }
            let picture =
                ((content["teaserImage"] as? [String: Any])?["default"]
                as? [String: Any])?["url"] as? String
            return NewsItem(
                id: content["urn"] as? String ?? link.absoluteString,
                source: .dr,
                title: title,
                summary: content["summary"] as? String ?? "",
                link: link,
                imageURL: picture.flatMap { URL(string: "\($0)?\(pictureQuery)") },
                publishedAt: (content["startDate"] as? String).flatMap { dates.date(from: $0) }
            )
        }
    }

    /// The page's `publications` array, or `nil` if the page no longer has that shape.
    private static func publications(in html: String) -> [[String: Any]]? {
        // Every push's string, decoded and joined: the tree can be split across several, and a
        // split may fall anywhere — mid-array included.
        let tree = html.matches(of: #/self\.__next_f\.push\(\[1,("(?:[^"\\]|\\.)*")\]\)/#)
            .compactMap { match in
                try? JSONSerialization.jsonObject(
                    with: Data(match.output.1.utf8), options: [.fragmentsAllowed]) as? String
            }
            .joined()
        guard let page = tree.range(of: #""name":"LatestNewsPage""#),
            let key = tree[page.upperBound...].range(of: #""publications":["#),
            // From the `[` the key search ended on, so the array opens at the start.
            let array = balancedJSON(from: tree[tree.index(before: key.upperBound)...]),
            let decoded = try? JSONSerialization.jsonObject(with: Data(array.utf8))
        else { return nil }
        return decoded as? [[String: Any]]
    }

    /// The JSON array that opens at the start of `text` — which must begin with its `[` — cut at
    /// the bracket that closes it. The tree goes on after it in a format of its own, so the decoder can't simply
    /// be pointed at the rest; brackets inside strings don't count.
    private static func balancedJSON(from text: Substring) -> Substring? {
        var depth = 0
        var inString = false
        var isEscaped = false
        for index in text.indices {
            let character = text[index]
            // Only ever set inside a string, so it needs no check of `inString` of its own.
            if isEscaped {
                isEscaped = false
                continue
            }
            if inString {
                if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            switch character {
            case "\"": inString = true
            case "[", "{": depth += 1
            case "]", "}":
                depth -= 1
                if depth == 0 { return text[...index] }
            default: break
            }
        }
        return nil
    }
}
