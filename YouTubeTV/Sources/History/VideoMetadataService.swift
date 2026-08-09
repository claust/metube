import Foundation

/// Looks a video up by id alone: its title, channel, artwork and running time.
///
/// The History screen is the reason this exists. Watch progress is a position, a duration and a
/// date per videoId — that is what syncs between boxes and what survives a reinstall — so a
/// history rebuilt from it is a list of ids with nothing to draw. Everything else in the app
/// gets its cards from a feed that was already showing them.
///
/// `player` on the VISIONOS client, which is the same call — and the same `visitorData` — the
/// player already makes to resolve a stream, minus the streaming half of the response. Nothing
/// else InnerTube offers answers "what is this video" for an id that isn't in some feed, and it
/// is a proven path in this app rather than a second one to keep working.
///
/// One video per request: InnerTube has no batch form of this. That is why the answers are
/// cached forever in `WatchHistoryStore` — a history looked up once stays looked up, and only
/// videos watched since cost anything on later visits.
struct VideoMetadataService {

    /// The card for `videoId`, or `nil` when the response carried no details — a video that has
    /// been deleted or made private, which is exactly the case a history is likely to hold.
    func load(videoId: String) async throws -> VideoItem? {
        var visitorData = try? await VisitorDataStore.shared.token()
        var json = try await post(videoId: videoId, visitorData: visitorData)

        // An expired token looks exactly like never having sent one, so retry once with a fresh
        // one — the same dance `StreamService` does, and for the same reason.
        if details(in: json) == nil, visitorData != nil {
            await VisitorDataStore.shared.invalidate()
            visitorData = try? await VisitorDataStore.shared.token()
            json = try await post(videoId: videoId, visitorData: visitorData)
        }

        guard let details = details(in: json) else { return nil }
        return item(id: videoId, details: details)
    }

    private func post(videoId: String, visitorData: String?) async throws -> [String: Any] {
        try await InnerTubeClient.post(
            endpoint: "player",
            client: .visionOS,
            params: [
                "videoId": videoId,
                "contentCheckOk": true,
                "racyCheckOk": true,
            ],
            bearer: nil,
            visitorData: visitorData
        )
    }

    private func details(in json: [String: Any]) -> [String: Any]? {
        guard let details = json["videoDetails"] as? [String: Any],
            let title = details["title"] as? String, !title.isEmpty
        else { return nil }
        return details
    }

    private func item(id: String, details: [String: Any]) -> VideoItem {
        let thumbs = (details.value(at: "thumbnail/thumbnails") as? [[String: Any]]) ?? []
        return VideoItem(
            id: id,
            title: details["title"] as? String ?? "",
            author: details["author"] as? String ?? "",
            channelID: details["channelId"] as? String,
            thumbnailURL: largestThumbnailURL(thumbs) ?? VideoItem.artworkURL(videoId: id),
            // Deliberately no view count: `videoDetails` gives an exact number ("1043277") where
            // every card in the app shows YouTube's own abbreviation ("1M views"), and inventing
            // a second house style for the same line is worse than leaving it off.
            duration: Self.durationText(seconds: details["lengthSeconds"] as? String)
        )
    }

    /// InnerTube's `lengthSeconds` as the badge on a thumbnail renders it — "21:55", "1:02:14".
    /// Empty for a live stream, which carries no length.
    static func durationText(seconds: String?) -> String {
        guard let seconds, let total = Int(seconds), total > 0 else { return "" }
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

extension VideoItem {
    /// YouTube's thumbnail for a video id, without asking anything for it. Every video has this
    /// file, so it is what a card falls back to while its lookup is still in flight — or after
    /// one that never came back.
    static func artworkURL(videoId: String) -> URL? {
        URL(string: "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg")
    }
}
