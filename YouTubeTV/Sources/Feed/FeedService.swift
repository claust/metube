import Foundation

/// Fetches and parses the personalized YouTube "Home" feed via the InnerTube TV client.
struct FeedService {

    /// Loads the first page of the signed-in Home recommendations, grouped into the shelves
    /// YouTube returns ("Recommended", "Recently uploaded", …). Calls `browse` with
    /// `browseId=default` on the TVHTML5 client using the user's OAuth token.
    func loadHome(accessToken: String) async throws -> FeedPage {
        try await loadFeed(.home, accessToken: accessToken)
    }

    /// Loads the first page of any browsable feed on the TVHTML5 client.
    ///
    /// Supplementary feeds get their first row retitled to name the feed. Subscriptions opens
    /// with a "Most relevant" shelf and History with an untitled one — neither says which feed
    /// it came from, which matters once the rows sit below Home.
    func loadFeed(_ feed: Feed, accessToken: String) async throws -> FeedPage {
        let json = try await InnerTubeClient.post(
            endpoint: "browse",
            client: .tv,
            params: ["browseId": feed.browseId],
            bearer: accessToken
        )
        var result = page(from: json, label: feed.browseId)

        if feed != .home, let first = result.sections.first {
            var sections = result.sections
            sections[0] = FeedSection(id: first.id, title: feed.title, items: first.items)
            result = FeedPage(sections: sections, continuation: result.continuation)
        }

        return result
    }

    /// Loads a further page of shelves using a token from a previous `FeedPage`.
    func loadMore(continuation: String, accessToken: String) async throws -> FeedPage {
        let json = try await InnerTubeClient.post(
            endpoint: "browse",
            client: .tv,
            params: ["continuation": continuation],
            bearer: accessToken
        )
        return page(from: json, label: "continuation")
    }

    /// Both the initial and continuation responses nest shelves the same way, so they share
    /// this parse. Only the wrapper around the section list differs.
    private func page(from json: [String: Any], label: String) -> FeedPage {
        var sections = parseSections(in: json)

        // Defensive fallback: the response carried no recognizable shelves, so present
        // everything playable in the tree as one untitled row rather than showing nothing.
        if sections.isEmpty {
            let items = parseItems(in: json)
            if !items.isEmpty {
                sections = [FeedSection(title: "", items: items)]
            }
        }

        let token = sectionListContinuation(in: json)

        #if DEBUG
        print(
            "[FeedService] \(label): \(sections.count) shelves: "
                + sections.map { "\($0.title.isEmpty ? "(untitled)" : $0.title)=\($0.items.count)" }
                .joined(separator: ", ") + " | more: \(token != nil)")
        #endif

        return FeedPage(sections: sections, continuation: token)
    }

    // MARK: - Continuation

    /// The token that fetches the next batch of shelves.
    ///
    /// The TVHTML5 feed uses the older `continuations[].nextContinuationData` style rather than
    /// `continuationItemRenderer` (verified 2026-07-26). Several of these exist per response —
    /// each shelf carries its own for scrolling further right within that row — so this reads
    /// `continuations` directly off the section-list container rather than searching the whole
    /// tree, which would otherwise return a single row's token and paginate the wrong axis.
    private func sectionListContinuation(in json: [String: Any]) -> String? {
        // `sectionListRenderer` on the first page; `sectionListContinuation` on later ones.
        for containerName in ["sectionListRenderer", "sectionListContinuation"] {
            for container in findAllRenderers(named: containerName, in: json) {
                guard let continuations = container["continuations"] as? [[String: Any]] else { continue }
                for entry in continuations {
                    for path in ["nextContinuationData/continuation", "reloadContinuationData/continuation"] {
                        if let token = entry.string(at: path), !token.isEmpty {
                            return token
                        }
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Shelf grouping

    /// Renderer names that wrap one horizontal row of the TV feed.
    private static let shelfRendererNames = ["shelfRenderer", "reelShelfRenderer"]

    /// Collects each shelf in the response as its own section, in document order.
    private func parseSections(in json: [String: Any]) -> [FeedSection] {
        var sections: [FeedSection] = []
        // Shelves can nest (a shelf whose content is itself shelf-shaped). Tracking every
        // videoId already emitted lets us drop a shelf that only repeats an earlier one,
        // without suppressing a video that legitimately appears in two different rows.
        var emitted = Set<String>()

        for shelf in findShelves(in: json) {
            var items = parseItems(in: shelf)
            guard !items.isEmpty else { continue }

            // A nested duplicate: every video here was already shown above.
            if items.allSatisfy({ emitted.contains($0.id) }) { continue }
            emitted.formUnion(items.map(\.id))

            // Within a row the ids must be unique — ForEach keys on them.
            items = dedupe(items)

            sections.append(FeedSection(title: shelfTitle(shelf) ?? "", items: items))
        }

        return sections
    }

    /// Collects every shelf-shaped renderer. Shelves sit in the `sectionListRenderer.contents`
    /// array, so array order — which is the order YouTube wants the rows displayed in — is
    /// preserved. This can't reuse `findAllRenderers` per name, which would group all shelves
    /// of one kind ahead of the other.
    ///
    /// Shelf keys are probed in a fixed order at each level, so a response mixing shelf kinds
    /// in one dictionary still parses deterministically without sorting the keys of every
    /// dictionary in a large response. Recursing after the probe also means an outer shelf is
    /// always emitted before any shelf nested inside it, which is what the nested-duplicate
    /// check in `parseSections` assumes.
    private func findShelves(in json: [String: Any]) -> [[String: Any]] {
        var results: [[String: Any]] = []
        func walk(_ obj: Any) {
            if let dict = obj as? [String: Any] {
                for name in Self.shelfRendererNames {
                    if let renderer = dict[name] as? [String: Any] {
                        results.append(renderer)
                    }
                }
                for value in dict.values { walk(value) }
            } else if let array = obj as? [Any] {
                for value in array { walk(value) }
            }
        }
        walk(json)
        return results
    }

    /// Shelf headings live under a few different renderers depending on the row type.
    /// The TVHTML5 home feed uses the `avatarLockup` variant (verified 2026-07-26); the rest
    /// are the shapes other browse responses use.
    private func shelfTitle(_ shelf: [String: Any]) -> String? {
        let paths = [
            "headerRenderer/shelfHeaderRenderer/avatarLockup/avatarLockupRenderer/title",
            "headerRenderer/shelfHeaderRenderer/title",
            "headerRenderer/gridHeaderRenderer/title",
            "header/shelfHeaderRenderer/title",
            "title",
        ]
        for path in paths {
            if let text = innerTubeText(shelf.value(at: path)), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    /// Tiles are the TV feed's primary cell type; grid/video renderers are the fallback shape.
    private func parseItems(in json: [String: Any]) -> [VideoItem] {
        let tiles = parseTiles(in: json)
        return tiles.isEmpty ? parseVideoRenderers(in: json) : tiles
    }

    private func dedupe(_ items: [VideoItem]) -> [VideoItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    // MARK: - tileRenderer parsing (primary path for the TV home feed)

    private func parseTiles(in json: [String: Any]) -> [VideoItem] {
        let tiles = findAllRenderers(named: "tileRenderer", in: json)
        var result: [VideoItem] = []
        var seen = Set<String>()

        for tile in tiles {
            // videoId: watchEndpoint (fallback reelWatchEndpoint). Tiles without one are
            // channels/playlists — skip them.
            guard let videoId = tileVideoId(tile) else { continue }

            // Leniency: keep it if it's a video content type OR simply has a watch videoId.
            let contentType = tile["contentType"] as? String
            if let contentType, contentType != "TILE_CONTENT_TYPE_VIDEO" {
                // Some non-video content types (channels/playlists) still carry endpoints;
                // only skip when we're sure it's not a video.
                if contentType.hasPrefix("TILE_CONTENT_TYPE_")
                    && (contentType.contains("CHANNEL") || contentType.contains("PLAYLIST"))
                {
                    continue
                }
            }

            guard !seen.contains(videoId) else { continue }
            seen.insert(videoId)

            let metadata = tile.value(at: "metadata/tileMetadataRenderer") as? [String: Any]
            let title = innerTubeText(metadata?["title"]) ?? ""
            let parts = tileMetadataParts(metadata)
            let thumbURL = tileThumbnailURL(tile) ?? Self.fallbackThumbnail(videoId)

            result.append(
                VideoItem(
                    id: videoId,
                    title: title,
                    author: parts.author,
                    thumbnailURL: thumbURL,
                    publishedAt: parts.publishedAt,
                    viewCount: parts.viewCount,
                    duration: Self.durationOverlay(in: tile)
                ))
        }

        return result
    }

    /// The running time YouTube stamps on the thumbnail. Both tiles and the older renderers
    /// carry it as a `thumbnailOverlayTimeStatusRenderer`, nested at slightly different depths,
    /// so this searches the subtree rather than naming a path. Live items carry the same
    /// renderer with "LIVE" in it, which reads wrong next to a running time — skip those.
    private static func durationOverlay(in json: [String: Any]) -> String {
        for overlay in findAllRenderers(named: "thumbnailOverlayTimeStatusRenderer", in: json) {
            guard let text = innerTubeText(overlay["text"]), !text.isEmpty else { continue }
            guard text.contains(":") else { continue }
            return text
        }
        return ""
    }

    private func tileVideoId(_ tile: [String: Any]) -> String? {
        if let id = tile.string(at: "onSelectCommand/watchEndpoint/videoId"), !id.isEmpty {
            return id
        }
        if let id = tile.string(at: "onSelectCommand/reelWatchEndpoint/videoId"), !id.isEmpty {
            return id
        }
        return nil
    }

    /// Splits a tile's subtitle lines into the three things worth showing.
    ///
    /// Which slot holds what varies by shelf, and one slot often carries several values at once
    /// ("1.2M views • 3 days ago"), so this flattens everything to bullet-separated fragments
    /// and classifies each by shape: an age is whatever parses as one, the view count is
    /// whatever mentions views, and the channel is the first fragment that is neither.
    private func tileMetadataParts(_ metadata: [String: Any]?) -> TileMetadata {
        let lines = metadata?["lines"] as? [[String: Any]] ?? []
        let fragments =
            lines
            .flatMap { ($0.value(at: "lineRenderer/items") as? [[String: Any]]) ?? [] }
            .compactMap { innerTubeText($0.value(at: "lineItemRenderer/text")) }
            .flatMap { $0.split(whereSeparator: { "•·|".contains($0) }) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var author = ""
        var viewCount = ""
        var publishedAt: Date?

        for fragment in fragments {
            if let date = RelativeTime.parse(fragment) {
                publishedAt = publishedAt ?? date
            } else if fragment.range(of: "view", options: .caseInsensitive) != nil {
                viewCount = viewCount.isEmpty ? fragment : viewCount
            } else if author.isEmpty {
                author = fragment
            }
        }

        return TileMetadata(author: author, viewCount: viewCount, publishedAt: publishedAt)
    }

    /// The classified subtitle values of one tile.
    private struct TileMetadata {
        let author: String
        let viewCount: String
        let publishedAt: Date?
    }

    /// Picks the largest-width thumbnail from the tile header.
    private func tileThumbnailURL(_ tile: [String: Any]) -> URL? {
        guard let thumbs = tile.value(at: "header/tileHeaderRenderer/thumbnail/thumbnails") as? [[String: Any]] else {
            return nil
        }
        return Self.largestThumbnailURL(thumbs)
    }

    // MARK: - Fallback parsing (gridVideoRenderer / videoRenderer)

    private func parseVideoRenderers(in json: [String: Any]) -> [VideoItem] {
        var result: [VideoItem] = []
        var seen = Set<String>()

        for name in ["gridVideoRenderer", "videoRenderer"] {
            let renderers = findAllRenderers(named: name, in: json)
            for r in renderers {
                guard let videoId = r["videoId"] as? String, !videoId.isEmpty,
                    !seen.contains(videoId)
                else { continue }
                seen.insert(videoId)

                let title = innerTubeText(r["title"]) ?? innerTubeText(r["headline"]) ?? ""
                let author =
                    innerTubeText(r.value(at: "longBylineText"))
                    ?? innerTubeText(r.value(at: "shortBylineText"))
                    ?? ""

                var thumbURL: URL?
                if let thumbs = r.value(at: "thumbnail/thumbnails") as? [[String: Any]] {
                    thumbURL = Self.largestThumbnailURL(thumbs)
                }
                thumbURL = thumbURL ?? Self.fallbackThumbnail(videoId)

                // These renderers name the age and view count outright instead of burying them
                // in subtitle lines. `shortViewCountText` is the abbreviated form ("1.2M views")
                // the tile path also yields; `viewCountText` spells it out and is the fallback.
                let published = innerTubeText(r["publishedTimeText"]).flatMap { RelativeTime.parse($0) }
                let views =
                    innerTubeText(r["shortViewCountText"]) ?? innerTubeText(r["viewCountText"]) ?? ""

                // `lengthText` is this shape's own field; the overlay is the shared fallback.
                let duration = innerTubeText(r["lengthText"]) ?? Self.durationOverlay(in: r)

                result.append(
                    VideoItem(
                        id: videoId, title: title, author: author, thumbnailURL: thumbURL,
                        publishedAt: published, viewCount: views, duration: duration))
            }
        }

        return result
    }

    // MARK: - Helpers

    /// Chooses the thumbnail with the largest `width` from an InnerTube thumbnails array.
    private static func largestThumbnailURL(_ thumbs: [[String: Any]]) -> URL? {
        let best = thumbs.max { a, b in
            let wa = (a["width"] as? Int) ?? (a["width"] as? Double).map(Int.init) ?? 0
            let wb = (b["width"] as? Int) ?? (b["width"] as? Double).map(Int.init) ?? 0
            return wa < wb
        }
        guard var urlString = best?["url"] as? String, !urlString.isEmpty else { return nil }
        // Some thumbnail URLs are protocol-relative (//i.ytimg.com/...).
        if urlString.hasPrefix("//") { urlString = "https:" + urlString }
        return URL(string: urlString)
    }

    private static func fallbackThumbnail(_ videoId: String) -> URL? {
        URL(string: "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg")
    }
}
