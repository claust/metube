import Foundation

/// Fetches and parses the personalized YouTube "Home" feed via the InnerTube TV client.
struct FeedService {

    /// Loads the signed-in Home recommendations.
    /// Calls `browse` with `browseId=default` on the TVHTML5 client using the user's OAuth token,
    /// then robustly walks the response tree for playable video tiles.
    func loadHome(accessToken: String) async throws -> [VideoItem] {
        let json = try await InnerTubeClient.post(
            endpoint: "browse",
            client: .tv,
            params: ["browseId": "default"],
            bearer: accessToken
        )

        var items = parseTiles(in: json)

        // Defensive fallback: if no tileRenderer cells were found (feed shape varies),
        // scan for classic grid/video renderers so the grid isn't empty.
        if items.isEmpty {
            items = parseVideoRenderers(in: json)
        }

        return items
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
            let author = tileAuthor(metadata) ?? ""
            let thumbURL = tileThumbnailURL(tile) ?? Self.fallbackThumbnail(videoId)

            result.append(VideoItem(id: videoId, title: title, author: author, thumbnailURL: thumbURL))
        }

        return result
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

    /// Digs the first available subtitle/author text out of the tile metadata lines.
    private func tileAuthor(_ metadata: [String: Any]?) -> String? {
        guard let lines = metadata?["lines"] as? [[String: Any]] else { return nil }
        for line in lines {
            guard let items = line.value(at: "lineRenderer/items") as? [[String: Any]] else { continue }
            for item in items {
                if let text = innerTubeText(item.value(at: "lineItemRenderer/text")),
                    !text.isEmpty
                {
                    return text
                }
            }
        }
        return nil
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

                result.append(VideoItem(id: videoId, title: title, author: author, thumbnailURL: thumbURL))
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
