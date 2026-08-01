import Foundation

/// Fetches the body text of a news article from the outlet's own page.
///
/// The RSS feed carries a headline and one sentence of standfirst — the story itself is only on
/// the article page, so reading it means fetching that page and pulling the text back out of it.
/// There is no API for this; the shape below is what BBC's pages happen to be built from, and it
/// can change under us without warning. Every failure mode therefore ends the same way: an empty
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

struct ArticleService {
    /// Bodies already fetched this session, so stepping back to a story is instant and a lap of
    /// the ticker doesn't refetch the same articles. Session-lived on purpose — news pages get
    /// corrected, and nothing here is worth persisting across launches.
    private static let cache = ArticleCache()

    /// The article's body in order, or an empty array when the page yielded no body — an index
    /// or live page rather than an article, a layout change, or a failed request.
    func body(for item: NewsItem) async -> [ArticleBlock] {
        if let cached = await Self.cache.blocks(forID: item.id) { return cached }
        guard let link = item.link else { return [] }

        var request = URLRequest(url: link)
        // BBC serves a stripped page to clients it doesn't recognise, and the embedded article
        // data this reads is missing from it.
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let blocks: [ArticleBlock]
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                let html = String(data: data, encoding: .utf8)
            else { return [] }
            blocks = Self.body(inPageHTML: html, headline: item.title)
        } catch {
            return []
        }

        // Cached even when empty: a page with no article body will have none next time either,
        // and re-fetching a few hundred KB on every left/right press to learn that again is the
        // one thing this cache exists to prevent.
        await Self.cache.store(blocks, forID: item.id)
        return blocks
    }

    private static let userAgent =
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
private actor ArticleCache {
    private var stored: [String: [ArticleBlock]] = [:]

    func blocks(forID id: String) -> [ArticleBlock]? { stored[id] }

    func store(_ blocks: [ArticleBlock], forID id: String) { stored[id] = blocks }
}
