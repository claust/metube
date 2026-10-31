import Foundation

/// Fetches the body text of a news article from the outlet's own page.
///
/// The RSS feed carries a headline and one sentence of standfirst — the story itself is only on
/// the article page, so reading it means fetching that page and pulling the text back out of it.
/// There is no API for this; each outlet's reader below follows what its pages happen to be
/// built from, and either can change under us without warning. Every failure mode therefore ends the same way: an empty
/// result, and the caller falls back to the summary the feed gave it.
/// One piece of an article's body.
struct ArticleBlock: Hashable {
    enum Kind: Hashable {
        case paragraph
        /// A section heading inside the article — BBC's `subheadline`. Kept apart from the prose
        /// because it reads as an interruption when it is set like a one-line paragraph.
        case subheading
    }

    let kind: Kind
    let text: String
}

/// What the reading panel takes from an article's page: the text, and the picture the outlet
/// chose for the story.
struct Article: Hashable {
    let blocks: [ArticleBlock]
    /// The page's `og:image` — what the outlet shows when the story is shared. Read because a
    /// feed item can arrive without a picture (DR's short news items never carry one), and the
    /// page is being fetched for its text anyway.
    let imageURL: URL?

    static let empty = Article(blocks: [], imageURL: nil)
}

struct ArticleService {
    /// Bodies already fetched this session, so stepping back to a story is instant and a lap of
    /// the ticker doesn't refetch the same articles. Session-lived on purpose — news pages get
    /// corrected, and nothing here is worth persisting across launches.
    private static let cache = ArticleCache()

    /// The article's body in order and its picture. The body is empty when the page yielded
    /// none — an index or live page rather than an article, a layout change, or a failed request.
    func article(for item: NewsItem) async -> Article {
        if let cached = await Self.cache.article(forID: item.id) { return cached }
        guard let link = item.link else { return .empty }

        var request = URLRequest(url: link)
        // BBC serves a stripped page to clients it doesn't recognise, and the embedded article
        // data this reads is missing from it.
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let article: Article
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                let html = String(data: data, encoding: .utf8)
            else { return .empty }
            let blocks: [ArticleBlock]
            switch item.source {
            case .bbc: blocks = Self.body(inPageHTML: html, headline: item.title)
            case .dr: blocks = Self.body(inDRPageHTML: html, focusID: Self.drFocusID(in: link))
            }
            article = Article(blocks: blocks, imageURL: Self.shareImageURL(inPageHTML: html))
        } catch {
            return .empty
        }

        // Cached even when empty: a page with no article body will have none next time either,
        // and re-fetching a few hundred KB on every left/right press to learn that again is the
        // one thing this cache exists to prevent.
        await Self.cache.store(article, forID: item.id)
        return article
    }

    /// The page's `og:image`, from either attribute order — DR writes `property` first, and
    /// nothing promises every page will.
    static func shareImageURL(inPageHTML html: String) -> URL? {
        guard let tag = html.firstMatch(of: #/<meta[^>]*property="og:image"[^>]*>/#)?.output,
            let content = tag.firstMatch(of: #/content="([^"]+)"/#)?.output.1
        else { return nil }
        return URL(string: decodingEntities(String(content)))
    }

    /// A desktop Safari's. Also what `NewsService` sends for DR's "Seneste nyt" page.
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// The marker BBC's pages assign their page model to.
    private static let marker = "__INITIAL_DATA__="

    /// Block types that are inside the article but are not the article: pictures and their
    /// captions, the headline, the byline, and the "related stories" promos BBC drops mid-text.
    /// Each of these carries paragraphs of its own, and without skipping them the body comes
    /// back with the headline twice and photo captions between the sentences.
    private static let skippedTypes: Set<String> = [
        "image", "rawImage", "video", "links", "link", "headline", "byline", "topicList",
        "metadata",
    ]

    /// Keys that hold the same furniture as `skippedTypes`, reached by name rather than by a
    /// `type` field.
    private static let skippedKeys: Set<String> = [
        "caption", "altText", "headline", "shortHeadline", "metadata", "byline",
    ]

    /// Pulls the article's paragraphs out of a BBC page.
    ///
    /// The page embeds its whole model as `__INITIAL_DATA__="…"` — a JSON document encoded as a
    /// JavaScript string literal, so it is escaped twice and has to be decoded twice. Text is
    /// read from the typed blocks rather than scraped from the markup: a `paragraph` block is
    /// unambiguously body text, where a `<p>` in the rendered page is just as likely to be a
    /// nav item or a photo credit.
    static func body(inPageHTML html: String, headline: String = "") -> [ArticleBlock] {
        guard let literal = jsonStringLiteral(after: marker, in: html),
            // The literal is itself valid JSON — a bare string — so the JSON decoder can undo
            // the JavaScript escaping exactly, which hand-rolled replacements would not.
            let inner = try? JSONSerialization.jsonObject(
                with: Data(literal.utf8), options: [.fragmentsAllowed]),
            let json = inner as? String,
            let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
            let data = (root as? [String: Any])?["data"] as? [String: Any]
        else { return [] }

        // The article is filed under a key carrying its whole query string
        // ("article?enableOTTAdvertsPlugin=false&…"), so it is found by prefix. The same page
        // model repeats the article in a couple of other stores; taking one copy is what keeps
        // the body from coming back three times over.
        guard let key = data.keys.first(where: { $0.hasPrefix("article") }) else { return [] }
        return withoutRepeatedHeadline(blocks(in: data[key] as Any), headline: headline)
    }

    /// The attribute DR's pages put on the element wrapping the article text.
    private static let drBodyMarker = "itemProp=\"articleBody\""

    /// The liveblog post a DR link points into, if it does. Sport headlines in DR's feed are
    /// often a single post in a running blog, linked as the blog's page plus `?focusId=<post>`.
    static func drFocusID(in link: URL) -> String? {
        URLComponents(url: link, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "focusId" }?.value
    }

    /// Pulls the article's paragraphs out of a DR page.
    ///
    /// DR renders the article server-side, so unlike BBC there is no page model to decode — the
    /// text is read from the markup, starting at the `articleBody` element. A short news item's
    /// page lists the neighbouring items below it, each with an `articleBody` of its own, so the
    /// read stops where the next one begins.
    ///
    /// A liveblog's `articleBody` is the blog's standing introduction, the same few words over
    /// every post, so a link into a blog reads the post and nothing else. The page only carries
    /// the newest posts; one that has scrolled out of it comes back empty, and the panel shows
    /// the headline alone rather than an introduction that says nothing about the story.
    static func body(inDRPageHTML html: String, focusID: String? = nil) -> [ArticleBlock] {
        if let focusID { return liveblogPost(focusID, inDRPageHTML: html) }
        guard let start = html.range(of: drBodyMarker) else { return [] }
        let rest = html[start.upperBound...]
        let end = rest.range(of: drBodyMarker)?.lowerBound ?? rest.endIndex

        // Body paragraphs and subheadings — `hydra-article-body-paragraph` on an article,
        // `hydra-latest-news-page-short-news-article__paragraph` on a short news item,
        // `hydra-article-body-sub-heading` for a heading. Matched on the `hydra-` class rather
        // than on bare `<p>`, because a fact box, a picture credit and the "more news" cards
        // are `<p>`s too.
        let block = #/<(p|h2) class="hydra-[^"]*(paragraph|sub-heading)[^"]*"[^>]*>(.*?)</\1>/#
            .dotMatchesNewlines()
        return rest[..<end].matches(of: block).compactMap { match in
            let text = plainText(fromHTML: String(match.output.3))
            guard !text.isEmpty else { return nil }
            let kind: ArticleBlock.Kind = match.output.2 == "sub-heading" ? .subheading : .paragraph
            return ArticleBlock(kind: kind, text: text)
        }
    }

    /// The liveblog post with this id, read from the page data Next.js streams into the page.
    ///
    /// The rendered page only carries the latest handful of posts, but the data behind it has
    /// each as `{"id":"<post>",…,"content":"<p>…</p>"}`, inside a `self.__next_f.push([1,"…"])`
    /// call — JSON written as a JavaScript string, so, as with BBC, decoded twice.
    private static func liveblogPost(_ id: String, inDRPageHTML html: String) -> [ArticleBlock] {
        guard let idRange = html.range(of: #"\"id\":\"\#(id)\""#),
            let push = html[..<idRange.lowerBound].range(
                of: "self.__next_f.push([1,", options: .backwards),
            let literal = jsonStringLiteral(
                after: "push([1,", in: String(html[push.lowerBound...])),
            let chunk = try? JSONSerialization.jsonObject(
                with: Data(literal.utf8), options: [.fragmentsAllowed]) as? String,
            let post = chunk.range(of: #""id":"\#(id)""#),
            let content = jsonStringLiteral(after: #""content":"#, in: String(chunk[post.upperBound...])),
            let markup = try? JSONSerialization.jsonObject(
                with: Data(content.utf8), options: [.fragmentsAllowed]) as? String
        else { return [] }

        return markup.matches(of: #/<p[^>]*>(.*?)</p>/#.dotMatchesNewlines()).compactMap { match in
            let text = plainText(fromHTML: String(match.output.1))
            return text.isEmpty ? nil : ArticleBlock(kind: .paragraph, text: text)
        }
    }

    /// A fragment of markup as the text it shows: tags dropped — links inside a paragraph keep
    /// their words — and entities decoded.
    private static func plainText(fromHTML fragment: String) -> String {
        let stripped = fragment.replacingOccurrences(
            of: "<[^>]+>", with: "", options: .regularExpression)
        return decodingEntities(stripped).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The named entities DR's markup uses, plus numeric ones. Not `NSAttributedString`'s HTML
    /// import, which would decode everything but spins up WebKit on the main thread to do it.
    private static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = [
            "&quot;": "\"", "&#x27;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">",
            "&nbsp;": " ",
        ]
        var result = text
        for (entity, character) in named {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        // Numeric references, decimal or hex.
        result.replace(#/&#(x?)([0-9a-fA-F]+);/#) { match in
            let radix = match.output.1.isEmpty ? 10 : 16
            guard let value = UInt32(match.output.2, radix: radix),
                let scalar = Unicode.Scalar(value)
            else { return String(match.output.0) }
            return String(Character(scalar))
        }
        // Last, so an escaped entity ("&amp;quot;") comes out as the text it spells.
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Drops an opening paragraph that is just the headline again.
    ///
    /// Some formats — BBC's "InDepth" pieces among them — carry the title inside the body's own
    /// blocks rather than in the `headline` block the walk already skips, so it arrives as the
    /// article's first sentence and is shown directly under the headline it repeats. Matched by
    /// text rather than by block shape, because the shape is what varies.
    private static func withoutRepeatedHeadline(_ blocks: [ArticleBlock], headline: String)
        -> [ArticleBlock]
    {
        func normalized(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard !headline.isEmpty, let first = blocks.first,
            normalized(first.text) == normalized(headline)
        else { return blocks }
        return Array(blocks.dropFirst())
    }

    /// The JavaScript string literal that follows `marker`, quotes included, or `nil` if the
    /// marker isn't there or the literal is unterminated.
    private static func jsonStringLiteral(after marker: String, in html: String) -> String? {
        guard let markerRange = html.range(of: marker) else { return nil }
        let rest = html[markerRange.upperBound...]
        guard let open = rest.firstIndex(of: "\"") else { return nil }

        // Hand-scanned rather than matched with a regex, because the closing quote is whichever
        // one isn't escaped, and the literal holds thousands of escaped quotes before it.
        var index = rest.index(after: open)
        var isEscaped = false
        while index < rest.endIndex {
            let character = rest[index]
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                return String(rest[open...index])
            }
            index = rest.index(after: index)
        }
        return nil
    }

    /// Walks a page-model subtree and collects every `paragraph` block in it.
    ///
    /// A subheading arrives as a `subheadline` wrapper around an ordinary text block, so the
    /// paragraph inside it is indistinguishable from body prose by the time it is reached. The
    /// walk therefore carries the wrapper's meaning down with it.
    private static func blocks(in value: Any) -> [ArticleBlock] {
        var collected: [ArticleBlock] = []

        func walk(_ value: Any, kind: ArticleBlock.Kind) {
            if let dictionary = value as? [String: Any] {
                let type = dictionary["type"] as? String
                if let type, skippedTypes.contains(type) { return }
                let childKind: ArticleBlock.Kind = type == "subheadline" ? .subheading : kind
                if type == "text" {
                    let model = dictionary["model"] as? [String: Any]
                    let inner = model?["blocks"] as? [[String: Any]] ?? []
                    for block in inner where block["type"] as? String == "paragraph" {
                        let text = (block["model"] as? [String: Any])?["text"] as? String
                        if let text, !text.isEmpty {
                            collected.append(ArticleBlock(kind: childKind, text: text))
                        }
                    }
                    return
                }
                // Paragraph order comes from the `blocks` arrays above, which are ordered;
                // dictionary iteration here only decides which *branch* is walked first, and
                // the body of a story lives in one branch.
                for (key, child) in dictionary where !skippedKeys.contains(key) {
                    walk(child, kind: childKind)
                }
            } else if let array = value as? [Any] {
                array.forEach { walk($0, kind: kind) }
            }
        }

        walk(value, kind: .paragraph)
        return collected
    }
}

/// Article bodies already fetched, keyed by the feed's item id.
///
/// Bounded, because a TV app's "session" is measured in days rather than minutes: only stories
/// the user actually stops on are ever fetched, so this fills slowly, but nothing here would
/// ever have let go of one.
private actor ArticleCache {
    /// How many bodies to keep. An article is a few kilobytes of text, so this is generous by
    /// design — it exists to put a ceiling on a week-long session, not to save memory in an
    /// evening's use.
    private static let capacity = 40

    private var stored: [String: Article] = [:]

    /// Keys in insertion order, oldest first. Age rather than least-recently-read: headlines
    /// only move forward, so the oldest body is also the one least likely to be asked for again,
    /// and tracking reads would mean rewriting this array on every cache hit.
    private var order: [String] = []

    func article(forID id: String) -> Article? { stored[id] }

    func store(_ article: Article, forID id: String) {
        if stored[id] == nil { order.append(id) }
        stored[id] = article
        while order.count > Self.capacity {
            stored.removeValue(forKey: order.removeFirst())
        }
    }
}
