import Foundation

/// Turns any InnerTube response subtree into `VideoItem`s.
///
/// Both `browse` (feeds) and `search` return the same video cells, so the cell parsing lives
/// here rather than in either service. Callers pass whatever scope they care about — a whole
/// response, or a single shelf — and get every playable video inside it, in document order.
enum VideoItemParser {

    /// Every video cell in `json`, deduped by videoId.
    ///
    /// YouTube mixes cell shapes freely — a single search response returns a couple of
    /// `tileRenderer`s alongside dozens of `lockupViewModel`s — so all known shapes are
    /// collected in one pass rather than one shape being tried as a fallback for another.
    /// Anything that isn't a playable video (channels, playlists) is dropped: this app can
    /// only open the player, so a card that leads nowhere is worse than one fewer card.
    ///
    /// Order follows the arrays cells sit in — `contents`, `items` — which is the order
    /// YouTube wants them shown in, and is what search relevance rides on. Between two
    /// branches of the same dictionary there is no document order to follow, so the walk
    /// takes them by sorted key: arbitrary, but the same on every run, which keeps both the
    /// result order and which duplicate `dedupe` keeps from shifting between identical
    /// responses. Cell keys are probed ahead of the recursion, so a dictionary that is
    /// itself a cell is emitted before anything nested inside it.
    static func items(in json: [String: Any]) -> [VideoItem] {
        var results: [VideoItem] = []

        func walk(_ obj: Any) {
            if let dict = obj as? [String: Any] {
                for shape in Shape.allCases {
                    if let cell = dict[shape.key] as? [String: Any], let item = shape.parse(cell) {
                        results.append(item)
                    }
                }
                for key in dict.keys.sorted() { walk(dict[key] as Any) }
            } else if let array = obj as? [Any] {
                for value in array { walk(value) }
            }
        }
        walk(json)

        return dedupe(results)
    }

    /// The cell renderers this app knows how to turn into a `VideoItem`.
    private enum Shape: CaseIterable {
        case tile  // TV feed and (partly) search
        case lockup  // the newer view-model shape search returns most of its hits in
        case gridVideo  // older browse responses
        case video  // older search/browse responses

        var key: String {
            switch self {
            case .tile: return "tileRenderer"
            case .lockup: return "lockupViewModel"
            case .gridVideo: return "gridVideoRenderer"
            case .video: return "videoRenderer"
            }
        }

        /// Returns `nil` when the cell isn't a playable video.
        func parse(_ cell: [String: Any]) -> VideoItem? {
            switch self {
            case .tile: return parseTile(cell)
            case .lockup: return parseLockup(cell)
            case .gridVideo, .video: return parseVideoRenderer(cell)
            }
        }
    }

    /// Keeps the first occurrence of each videoId. Ids must be unique within anything a
    /// `ForEach` renders, and YouTube repeats videos freely — both across rows and, now that
    /// several cell shapes coexist, within one row via two cells for the same video.
    private static func dedupe(_ items: [VideoItem]) -> [VideoItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }
}

// MARK: - tileRenderer (the TV feed's cell)

private func parseTile(_ tile: [String: Any]) -> VideoItem? {
    // videoId: watchEndpoint (fallback reelWatchEndpoint). Tiles without one are
    // channels/playlists — skip them.
    guard let videoId = tileVideoId(tile) else { return nil }

    // Leniency: keep it if it's a video content type OR simply has a watch videoId.
    let contentType = tile["contentType"] as? String
    if let contentType, contentType != "TILE_CONTENT_TYPE_VIDEO" {
        // Some non-video content types (channels/playlists) still carry endpoints;
        // only skip when we're sure it's not a video.
        if contentType.hasPrefix("TILE_CONTENT_TYPE_")
            && (contentType.contains("CHANNEL") || contentType.contains("PLAYLIST"))
        {
            return nil
        }
    }

    let metadata = tile.value(at: "metadata/tileMetadataRenderer") as? [String: Any]
    let lines = metadata?["lines"] as? [[String: Any]] ?? []
    let parts = Subtitle(
        fragments:
            lines
            .flatMap { ($0.value(at: "lineRenderer/items") as? [[String: Any]]) ?? [] }
            .compactMap { innerTubeText($0.value(at: "lineItemRenderer/text")) })

    return VideoItem(
        id: videoId,
        title: innerTubeText(metadata?["title"]) ?? "",
        author: parts.author,
        channelID: channelID(in: tile),
        thumbnailURL: tileThumbnailURL(tile) ?? fallbackThumbnail(videoId),
        channelAvatarURL: channelAvatarURL(in: tile),
        publishedAt: parts.publishedAt,
        viewCount: parts.viewCount,
        duration: durationOverlay(in: tile)
    )
}

private func tileVideoId(_ tile: [String: Any]) -> String? {
    for path in ["onSelectCommand/watchEndpoint/videoId", "onSelectCommand/reelWatchEndpoint/videoId"] {
        if let id = tile.string(at: path), !id.isEmpty { return id }
    }
    return nil
}

/// Picks the largest-width thumbnail from the tile header.
private func tileThumbnailURL(_ tile: [String: Any]) -> URL? {
    guard let thumbs = tile.value(at: "header/tileHeaderRenderer/thumbnail/thumbnails") as? [[String: Any]] else {
        return nil
    }
    return largestThumbnailURL(thumbs)
}

// MARK: - lockupViewModel (search results)

/// The view-model cell YouTube now returns most search hits in. It shares nothing with the
/// renderer shapes above — flat `content*` fields and `{"content": "…"}` strings instead of
/// nested renderers and `runs`/`simpleText` — so it needs its own reader throughout.
private func parseLockup(_ lockup: [String: Any]) -> VideoItem? {
    // Playlists and channels use the same cell with a non-video contentType, and their
    // `contentId` is a playlist/channel id — handing one to the player would 404.
    guard (lockup["contentType"] as? String) == "LOCKUP_CONTENT_TYPE_VIDEO" else { return nil }
    guard let videoId = lockupVideoId(lockup) else { return nil }

    let metadata = lockup.value(at: "metadata/lockupMetadataViewModel") as? [String: Any]
    let rows = metadata?.value(at: "metadata/contentMetadataViewModel/metadataRows") as? [[String: Any]] ?? []
    let parts = Subtitle(
        fragments:
            rows
            .flatMap { ($0["metadataParts"] as? [[String: Any]]) ?? [] }
            .compactMap { $0.string(at: "text/content") })

    return VideoItem(
        id: videoId,
        title: metadata?.string(at: "title/content") ?? "",
        author: parts.author,
        channelID: channelID(in: lockup),
        thumbnailURL: lockupThumbnailURL(lockup) ?? fallbackThumbnail(videoId),
        channelAvatarURL: channelAvatarURL(in: lockup),
        publishedAt: parts.publishedAt,
        viewCount: parts.viewCount,
        duration: lockupDuration(lockup)
    )
}

/// `contentId` is the videoId for a video lockup; the tap command carries it too, and is the
/// fallback for a cell that ever omits the flat field.
private func lockupVideoId(_ lockup: [String: Any]) -> String? {
    if let id = lockup["contentId"] as? String, !id.isEmpty { return id }
    let path = "rendererContext/commandContext/onTap/innertubeCommand/watchEndpoint/videoId"
    if let id = lockup.string(at: path), !id.isEmpty { return id }
    return nil
}

/// The running time, stamped on the thumbnail as a badge rather than the renderers'
/// `thumbnailOverlayTimeStatusRenderer`. Live items badge the same slot with "LIVE", which
/// reads wrong beside a running time, so this takes only what looks like a clock value.
private func lockupDuration(_ lockup: [String: Any]) -> String {
    for badge in findAllRenderers(named: "thumbnailBadgeViewModel", in: lockup) {
        guard let text = badge["text"] as? String, text.contains(":") else { continue }
        return text
    }
    return ""
}

private func lockupThumbnailURL(_ lockup: [String: Any]) -> URL? {
    let path = "contentImage/thumbnailViewModel/image/sources"
    guard let sources = lockup.value(at: path) as? [[String: Any]] else { return nil }
    return largestThumbnailURL(sources)
}

// MARK: - gridVideoRenderer / videoRenderer (older browse and search responses)

private func parseVideoRenderer(_ renderer: [String: Any]) -> VideoItem? {
    guard let videoId = renderer["videoId"] as? String, !videoId.isEmpty else { return nil }

    var thumbURL: URL?
    if let thumbs = renderer.value(at: "thumbnail/thumbnails") as? [[String: Any]] {
        thumbURL = largestThumbnailURL(thumbs)
    }

    // These renderers name the age and view count outright instead of burying them in
    // subtitle lines. `shortViewCountText` is the abbreviated form ("1.2M views") the tile
    // path also yields; `viewCountText` spells it out and is the fallback.
    let published = innerTubeText(renderer["publishedTimeText"]).flatMap { RelativeTime.parse($0) }
    let views = innerTubeText(renderer["shortViewCountText"]) ?? innerTubeText(renderer["viewCountText"]) ?? ""

    return VideoItem(
        id: videoId,
        title: innerTubeText(renderer["title"]) ?? innerTubeText(renderer["headline"]) ?? "",
        author: innerTubeText(renderer.value(at: "longBylineText"))
            ?? innerTubeText(renderer.value(at: "shortBylineText")) ?? "",
        channelID: channelID(in: renderer),
        thumbnailURL: thumbURL ?? fallbackThumbnail(videoId),
        channelAvatarURL: channelAvatarURL(in: renderer),
        publishedAt: published,
        viewCount: views,
        // `lengthText` is this shape's own field; the overlay is the shared fallback.
        duration: innerTubeText(renderer["lengthText"]) ?? durationOverlay(in: renderer)
    )
}

// MARK: - Shared helpers

/// The three things worth showing, picked out of a cell's subtitle text.
///
/// Which slot holds what varies by shelf and by cell shape, and one slot often carries several
/// values at once ("1.2M views • 3 days ago"), so this flattens everything to bullet-separated
/// fragments and classifies each by shape: an age is whatever parses as one, the view count is
/// whatever mentions views, and the channel is the first fragment that is neither. Tiles and
/// lockups reach their fragments by completely different paths but agree once flattened.
private struct Subtitle {
    let author: String
    let viewCount: String
    let publishedAt: Date?

    init(fragments: [String]) {
        var author = ""
        var viewCount = ""
        var publishedAt: Date?

        for fragment
            in fragments
            .flatMap({ $0.split(whereSeparator: { "•·|".contains($0) }) })
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .filter({ !$0.isEmpty })
        {
            if let date = RelativeTime.parse(fragment) {
                publishedAt = publishedAt ?? date
            } else if fragment.range(of: "view", options: .caseInsensitive) != nil {
                viewCount = viewCount.isEmpty ? fragment : viewCount
            } else if author.isEmpty {
                author = fragment
            }
        }

        self.author = author
        self.viewCount = viewCount
        self.publishedAt = publishedAt
    }
}

/// The running time YouTube stamps on the thumbnail. Both tiles and the older renderers
/// carry it as a `thumbnailOverlayTimeStatusRenderer`, nested at slightly different depths,
/// so this searches the subtree rather than naming a path. Live items carry the same
/// renderer with "LIVE" in it, which reads wrong next to a running time — skip those.
private func durationOverlay(in json: [String: Any]) -> String {
    for overlay in findAllRenderers(named: "thumbnailOverlayTimeStatusRenderer", in: json) {
        guard let text = innerTubeText(overlay["text"]), !text.isEmpty else { continue }
        guard text.contains(":") else { continue }
        return text
    }
    return ""
}

/// The channel's avatar, found by what the URL looks like rather than by path.
///
/// Every cell shape buries it somewhere different — `channelThumbnailSupportedRenderers` on the
/// old renderers, an `avatarViewModel` (sometimes wrapped in a `decoratedAvatarViewModel`) on
/// lockups, and the TV tiles vary by shelf — but all of them serve avatars from Google's
/// profile-picture hosts, which nothing else in a video cell uses. So this collects every image
/// list in the cell and keeps the ones served from those hosts.
///
/// The `UC…` id of the channel a cell belongs to.
///
/// Every shape carries it as a `browseEndpoint`, but somewhere different each time — on the
/// byline for the renderer shapes, and buried in the long-press menu's "Go to channel" item for
/// the TV tiles — so this searches the cell for browse endpoints rather than naming a path. A
/// channel id is the only `browseId` in a video cell that starts with `UC`; feed ids (`FEhistory`)
/// and playlist ids don't, so the prefix is what separates them.
private func channelID(in cell: [String: Any]) -> String? {
    var found: String?
    func walk(_ obj: Any) {
        guard found == nil else { return }
        if let dict = obj as? [String: Any] {
            if let id = dict.string(at: "browseEndpoint/browseId"), id.hasPrefix("UC") {
                found = id
                return
            }
            // Sorted so the same response always yields the same id, in the rare cell that
            // mentions two channels.
            for key in dict.keys.sorted() { walk(dict[key] as Any) }
        } else if let array = obj as? [Any] {
            for value in array { walk(value) }
        }
    }
    walk(cell)
    return found
}

/// Returns `nil` when the cell carries no avatar at all — which is the common case: the TV
/// feed's tiles never do, and their avatars come from `ChannelAvatarStore` instead.
private func channelAvatarURL(in cell: [String: Any]) -> URL? {
    var candidates: [[String: Any]] = []
    func walk(_ obj: Any) {
        if let dict = obj as? [String: Any] {
            for key in ["thumbnails", "sources"] {
                if let images = dict[key] as? [[String: Any]] { candidates.append(contentsOf: images) }
            }
            for value in dict.values { walk(value) }
        } else if let array = obj as? [Any] {
            for value in array { walk(value) }
        }
    }
    walk(cell)

    return avatarURL(from: candidates)
}

/// Picks the avatar to draw out of an image list, or `nil` if the list holds no avatar.
///
/// Avatars are recognised by host: they come from Google's profile-picture domains, which
/// nothing else in a browse response uses. Sizes arrive as a ladder of squares (48/88/176) and
/// the smallest one that still covers how big the card draws it wins — larger is wasted bytes
/// across a screenful of cards, smaller goes soft.
func avatarURL(from images: [[String: Any]]) -> URL? {
    func width(_ image: [String: Any]) -> Int {
        (image["width"] as? Int) ?? (image["width"] as? Double).map(Int.init) ?? 0
    }

    let avatars = images.filter { image in
        guard let url = image["url"] as? String else { return false }
        return url.contains("yt3.ggpht.com") || url.contains("yt3.googleusercontent.com")
            || url.contains("/ytc/")
    }
    guard !avatars.isEmpty else { return nil }

    let wanted = 176  // the 88pt circle at the TV's 2x scale
    let best =
        avatars.filter { width($0) >= wanted }.min { width($0) < width($1) }
        ?? avatars.max { width($0) < width($1) }
    guard var urlString = best?["url"] as? String, !urlString.isEmpty else { return nil }
    if urlString.hasPrefix("//") { urlString = "https:" + urlString }
    if width(best ?? [:]) < wanted { urlString = resized(urlString, to: wanted) }
    return URL(string: urlString)
}

/// Asks Google's image CDN for a bigger render of the same avatar.
///
/// The size lives in the URL as an `=s72-c-k-…` suffix and the CDN honours whatever is asked
/// for, which matters because a channel page only ever offers 72px — a quarter of what an 88pt
/// circle needs on a TV, and visibly soft at that size. Returns the URL untouched if it doesn't
/// carry a size token.
private func resized(_ urlString: String, to size: Int) -> String {
    guard let marker = urlString.range(of: "=s", options: .backwards) else { return urlString }
    let digits = urlString[marker.upperBound...].prefix { $0.isNumber }
    guard !digits.isEmpty else { return urlString }
    return urlString.replacingCharacters(
        in: marker.upperBound..<digits.endIndex, with: String(size))
}

/// Chooses the widest entry of an image array. Shared with the channel header, which picks an
/// avatar the same way. Covers both the renderer shape
/// (`thumbnails[]`) and the view-model shape (`image.sources[]`), which agree on
/// `url`/`width` even though nothing else about them matches.
func largestThumbnailURL(_ thumbs: [[String: Any]]) -> URL? {
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

private func fallbackThumbnail(_ videoId: String) -> URL? {
    URL(string: "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg")
}
