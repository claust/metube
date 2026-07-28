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

        // Skips a leading Shorts row: it says what it holds, and naming it after the feed would
        // both lose that and leave the feed's own heading on the wrong row.
        if feed != .home, let index = result.sections.firstIndex(where: { !$0.isShorts }) {
            var sections = result.sections
            let first = sections[index]
            sections[index] = FeedSection(
                id: first.id, title: feed.title, items: first.items,
                continuation: first.continuation)
            result = FeedPage(
                sections: sections, continuation: result.continuation,
                channelAvatars: result.channelAvatars)
        }

        return result
    }

    /// Loads a channel's page: its header details plus its shelves, parsed exactly like a feed's.
    ///
    /// A channel is just another `browseId`, so this is the same call the feeds make. Only the
    /// header is new — the channel's name, avatar and, usefully, whether the account already
    /// subscribes to it, which is the one authoritative answer to that question we can get for
    /// a single channel.
    func loadChannel(id: String, accessToken: String) async throws -> ChannelPage {
        let json = try await InnerTubeClient.post(
            endpoint: "browse",
            client: .tv,
            params: ["browseId": id],
            bearer: accessToken
        )
        return ChannelPage(
            title: channelTitle(in: json) ?? "",
            avatarURL: channelAvatarURL(in: json),
            bannerURL: channelBannerURL(in: json),
            isSubscribed: subscribedState(in: json),
            feed: page(from: json, label: "channel \(id)")
        )
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

    /// Loads more videos for one row, using the token from that `FeedSection`.
    ///
    /// The TV feed hands each shelf only its first few videos (3–6, verified 2026-07-27) and a
    /// token for the rest, so without this every row is a near-empty stub. Same `browse` call as
    /// shelf paging — only the token differs — but the reply is a bare list of videos rather
    /// than a section list.
    func loadMoreItems(continuation: String, accessToken: String) async throws -> FeedRowPage {
        let json = try await InnerTubeClient.post(
            endpoint: "browse",
            client: .tv,
            params: ["continuation": continuation],
            bearer: accessToken
        )
        let items = VideoItemParser.items(in: json)
        let token = rowContinuation(in: json)

        #if DEBUG
        print("[FeedService] row continuation: \(items.count) items | more: \(token != nil)")
        #endif

        return FeedRowPage(items: items, continuation: token)
    }

    /// Both the initial and continuation responses nest shelves the same way, so they share
    /// this parse. Only the wrapper around the section list differs.
    private func page(from json: [String: Any], label: String) -> FeedPage {
        var sections = parseSections(in: json)

        // Defensive fallback: the response carried no recognizable shelves, so present
        // everything playable in the tree as one untitled row rather than showing nothing.
        // Shorts still get a row of their own — the point of separating them isn't the shelf
        // structure, it's that a portrait tile doesn't belong in a landscape row.
        if sections.isEmpty {
            let items = VideoItemParser.items(in: json)
            let videos = items.filter { !$0.isShort }
            if !videos.isEmpty {
                sections = [FeedSection(title: "", items: videos)]
            }
            sections = merging(items.filter(\.isShort), into: sections)
        }

        let token = sectionListContinuation(in: json)
        let avatars = channelAvatars(in: json)

        #if DEBUG
        print(
            "[FeedService] \(label): \(sections.count) shelves: "
                + sections.map {
                    "\($0.title.isEmpty ? "(untitled)" : $0.title)=\($0.items.count)"
                        + ($0.isShorts ? "(shorts)" : "") + ($0.continuation != nil ? "+" : "")
                }
                .joined(separator: ", ") + " | more: \(token != nil)")
        #endif

        return FeedPage(sections: sections, continuation: token, channelAvatars: avatars)
    }

    /// The channel pictures hiding in the Subscriptions response's filter bar.
    ///
    /// That bar is a `tvSecondaryNavRenderer` of `tabRenderer`s — "All" followed by one tab per
    /// channel you follow, each with its name and its avatar in the usual size ladder
    /// (48/88/176). Nothing else in a browse response pictures a channel, so this is where the
    /// cards' avatars come from. Tabs are matched on having both a title and a thumbnail, which
    /// skips "All" without hard-coding its label.
    private func channelAvatars(in json: [String: Any]) -> [String: URL] {
        var found: [String: URL] = [:]
        for tab in findAllRenderers(named: "tabRenderer", in: json) {
            guard let name = innerTubeText(tab["title"]) ?? tab["title"] as? String,
                !name.isEmpty,
                let thumbs = tab.value(at: "thumbnail/thumbnails") as? [[String: Any]],
                let url = avatarURL(from: thumbs)
            else { continue }
            found[name] = url
        }
        return found
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
        continuation(in: json, containers: ["sectionListRenderer", "sectionListContinuation"])
    }

    /// The token that fetches more videos for one row, read off the row's own list container.
    ///
    /// `horizontalListRenderer` is the shape inside a shelf on any first page;
    /// `horizontalListContinuation` is what a row continuation replies with. Grid variants are
    /// included because some browse responses lay a row out as a grid instead.
    private func rowContinuation(in json: [String: Any]) -> String? {
        continuation(
            in: json,
            containers: [
                "horizontalListRenderer", "horizontalListContinuation",
                "gridRenderer", "gridContinuation",
            ])
    }

    /// First `continuations[]` token found on any of the named containers.
    ///
    /// Reading off a named container rather than searching the whole tree matters: a response
    /// carries tokens for both axes, so a blind search would happily paginate the wrong one.
    private func continuation(in json: [String: Any], containers: [String]) -> String? {
        for containerName in containers {
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

    /// One shelf renderer, with which kind of shelf it was — the only thing that identifies a
    /// Shorts row before its cells have been looked at.
    private struct Shelf {
        let renderer: [String: Any]
        let isReel: Bool
    }

    /// Renderer names that wrap one horizontal row of the TV feed. `reelShelfRenderer` is the
    /// Shorts row's own wrapper, and the one shelf kind whose contents are Shorts by definition.
    private static let shelfRendererNames = ["shelfRenderer", "reelShelfRenderer"]
    private static let reelShelfRendererName = "reelShelfRenderer"

    /// The heading a synthesized Shorts row gets — one built out of the Shorts that were mixed
    /// into ordinary shelves, when the response has no Shorts shelf of its own to add them to.
    private static let shortsShelfTitle = "Shorts"

    /// Collects each shelf in the response as its own section, in document order.
    ///
    /// Shorts are separated out as it goes: a Shorts shelf becomes a Shorts section, and the
    /// Shorts YouTube mixes into ordinary shelves (Recommended included) are lifted out of them
    /// and collected into the response's Shorts row instead, so a portrait tile never turns up
    /// mid-row among landscape ones.
    private func parseSections(in json: [String: Any]) -> [FeedSection] {
        var sections: [FeedSection] = []
        // Shelves can nest (a shelf whose content is itself shelf-shaped). Tracking every
        // videoId already emitted lets us drop a shelf that only repeats an earlier one,
        // without suppressing a video that legitimately appears in two different rows.
        var emitted = Set<String>()
        // Shorts pulled out of ordinary shelves, in the order they were met. Merged in below,
        // once every shelf has been seen and it's known whether the response has a Shorts row.
        var strayShorts: [VideoItem] = []

        for shelf in findShelves(in: json) {
            let items = VideoItemParser.items(in: shelf.renderer)
            guard !items.isEmpty else { continue }

            // A nested duplicate: every video here was already shown above.
            if items.allSatisfy({ emitted.contains($0.id) }) { continue }
            emitted.formUnion(items.map(\.id))

            // The shelf's own kind comes first: a reel shelf is a Shorts row whatever its cells
            // happen to look like. A shelf of nothing but Shorts is one too — which is how a
            // Shorts row laid out as an ordinary shelf still reads as one.
            let isShorts = shelf.isReel || items.allSatisfy(\.isShort)
            let title = shelfTitle(shelf.renderer) ?? ""
            let continuation = rowContinuation(in: shelf.renderer)

            if isShorts {
                sections.append(
                    FeedSection(
                        title: title.isEmpty ? Self.shortsShelfTitle : title,
                        items: items.map { $0.asShort() },
                        continuation: continuation, isShorts: true))
                continue
            }

            strayShorts.append(contentsOf: items.filter(\.isShort))
            let videos = items.filter { !$0.isShort }
            // Everything in the shelf was a Short, and they've been kept for the Shorts row.
            guard !videos.isEmpty else { continue }

            sections.append(
                FeedSection(title: title, items: videos, continuation: continuation))
        }

        return merging(strayShorts, into: sections)
    }

    /// Puts the Shorts lifted out of ordinary shelves where they belong: appended to the
    /// response's own Shorts row if it has one, or a Shorts row of their own at the end if it
    /// doesn't. Without this a Short filtered out of Recommended would simply disappear.
    private func merging(_ shorts: [VideoItem], into sections: [FeedSection]) -> [FeedSection] {
        guard !shorts.isEmpty else { return sections }
        var sections = sections

        if let index = sections.firstIndex(where: \.isShorts) {
            let existing = Set(sections[index].items.map(\.id))
            let fresh = shorts.filter { !existing.contains($0.id) }
            guard !fresh.isEmpty else { return sections }
            sections[index] = FeedSection(
                id: sections[index].id, title: sections[index].title,
                items: sections[index].items + fresh,
                continuation: sections[index].continuation, isShorts: true)
        } else {
            sections.append(
                FeedSection(title: Self.shortsShelfTitle, items: shorts, isShorts: true))
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
    private func findShelves(in json: [String: Any]) -> [Shelf] {
        var results: [Shelf] = []
        func walk(_ obj: Any) {
            if let dict = obj as? [String: Any] {
                for name in Self.shelfRendererNames {
                    if let renderer = dict[name] as? [String: Any] {
                        results.append(
                            Shelf(renderer: renderer, isReel: name == Self.reelShelfRendererName))
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

    // MARK: - Channel header

    /// The channel's name.
    ///
    /// `channelHeaderRenderer` is what TVHTML5 answers with (verified 2026-07-28 across four
    /// channels). `c4TabbedHeaderRenderer` and `pageHeaderRenderer` are the web shapes, kept as
    /// fallbacks in case a channel or a client bump hands back one of those instead. All three
    /// are searched for rather than pathed to, because which one arrives varies.
    private func channelTitle(in json: [String: Any]) -> String? {
        for name in ["channelHeaderRenderer", "c4TabbedHeaderRenderer"] {
            for header in findAllRenderers(named: name, in: json) {
                if let text = innerTubeText(header["title"]) ?? header["title"] as? String,
                    !text.isEmpty
                {
                    return text
                }
            }
        }
        for header in findAllRenderers(named: "pageHeaderRenderer", in: json) {
            if let text = header["pageTitle"] as? String, !text.isEmpty { return text }
        }
        return nil
    }

    private func channelAvatarURL(in json: [String: Any]) -> URL? {
        for name in ["channelHeaderRenderer", "c4TabbedHeaderRenderer"] {
            for header in findAllRenderers(named: name, in: json) {
                guard let thumbs = header.value(at: "avatar/thumbnails") as? [[String: Any]] else {
                    continue
                }
                // By path, not by host: the header's banner is served from the same CDN as its
                // avatar, so a host test can't tell them apart. Same reasoning as
                // `ChannelAvatarService`.
                if let url = avatarURL(from: thumbs) { return url }
            }
        }
        return nil
    }

    /// The channel's banner, for drawing behind the header.
    ///
    /// TVHTML5 hands back the 16:9 crop of it (the URLs carry `fcrop64`), not the wide strip
    /// youtube.com shows, so it can go full-bleed behind the header as-is. The rungs run
    /// 320×180 up to 2120×1192; `bannerWidth` picks the one that covers a 1080p screen without
    /// paying for the oversize top rung.
    private func channelBannerURL(in json: [String: Any]) -> URL? {
        for name in ["channelHeaderRenderer", "c4TabbedHeaderRenderer"] {
            for header in findAllRenderers(named: name, in: json) {
                let thumbs =
                    header.value(at: "backgroundImage/thumbnails") as? [[String: Any]]
                    ?? header.value(at: "banner/thumbnails") as? [[String: Any]]
                guard let thumbs, !thumbs.isEmpty else { continue }
                if let url = bannerURL(from: thumbs) { return url }
            }
        }
        return nil
    }

    /// The narrowest rung that still covers the screen, falling back to the widest on offer.
    private func bannerURL(from thumbs: [[String: Any]]) -> URL? {
        func width(_ image: [String: Any]) -> Int { (image["width"] as? NSNumber)?.intValue ?? 0 }
        let wanted = 1920
        let best =
            thumbs.filter { width($0) >= wanted }.min { width($0) < width($1) }
            ?? thumbs.max { width($0) < width($1) }
        guard var urlString = best?["url"] as? String, !urlString.isEmpty else { return nil }
        if urlString.hasPrefix("//") { urlString = "https:" + urlString }
        return URL(string: urlString)
    }

    /// Whether the account subscribes to this channel, per the header's own subscribe button.
    /// `nil` when the response carried no such button — a channel page fetched without a usable
    /// token, for instance — which the caller must not read as "not subscribed".
    private func subscribedState(in json: [String: Any]) -> Bool? {
        for button in findAllRenderers(named: "subscribeButtonRenderer", in: json) {
            if let subscribed = button["subscribed"] as? Bool { return subscribed }
        }
        return nil
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
}
