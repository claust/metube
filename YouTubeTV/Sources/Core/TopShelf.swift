import Foundation

/// One tile on the tvOS Top Shelf — the strip that appears above the app's icon while the icon
/// is focused on the home screen's top row.
///
/// Deliberately its own type rather than reusing `VideoItem`: this is a serialized contract
/// between two processes (the app writes it, the Top Shelf extension reads it), so it carries
/// only what a tile draws plus the id needed to open the player, and changing `VideoItem`
/// mustn't silently change what an already-installed extension expects to decode.
struct TopShelfVideo: Codable, Hashable {
    let id: String
    let title: String
    let author: String
    let thumbnailURL: URL?
}

/// The handful of feed videos the app hands to its Top Shelf extension, in the app group both
/// share.
///
/// The extension does no fetching of its own. It has no OAuth token, tvOS gives it a short
/// window to answer in, and it can be asked for content while the app has never run this boot —
/// so instead the app writes a snapshot each time the Home feed loads and the extension only
/// decodes it. The cost is staleness: the tiles show the feed as of the last time the app was
/// open, which is the same bargain every Top Shelf that isn't a background-refresh service makes.
enum TopShelfStore {
    /// Shared between the app and the extension. Both targets carry it as an
    /// `com.apple.security.application-groups` entitlement; see `project.yml`.
    static let appGroupID = "group.dk.delectosoft.metube"

    /// How many videos the Top Shelf shows. tvOS gives a focused top-row icon room for a
    /// handful of tiles; two keeps them large and matches what the feed leads with.
    static let itemCount = 2

    private static let videosKey = "yt.topShelf.videos"

    /// `nil` when the app group isn't provisioned — a device build signed by a team without the
    /// capability. Everything here then no-ops and the Top Shelf simply stays empty, rather
    /// than the app trapping on a store it can't open.
    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroupID) }

    static var videos: [TopShelfVideo] {
        guard let data = defaults?.data(forKey: videosKey),
            let decoded = try? JSONDecoder().decode([TopShelfVideo].self, from: data)
        else { return [] }
        return decoded
    }

    static func save(_ videos: [TopShelfVideo]) {
        guard let data = try? JSONEncoder().encode(videos) else { return }
        defaults?.set(data, forKey: videosKey)
    }

    /// Called when the last profile signs out. A signed-out app showing the previous account's
    /// recommendations on the home screen — where anyone walking past sees them — is worse than
    /// showing nothing.
    static func clear() {
        defaults?.removeObject(forKey: videosKey)
    }
}

/// The custom-scheme URLs that carry a Top Shelf tile's tap into the app.
///
/// A tile's action is a URL, so this is the one piece of the feature both processes have to
/// agree on character for character — hence building and parsing it in one shared place rather
/// than formatting a string at each end.
enum TopShelfLink {
    static let scheme = "metube"
    private static let videoHost = "video"
    private static let videoIDQueryItem = "id"

    /// `metube://video?id=<videoId>` — what the extension attaches to a tile.
    static func playURL(videoID: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = videoHost
        components.queryItems = [URLQueryItem(name: videoIDQueryItem, value: videoID)]
        return components.url
    }

    /// The video id in a URL the app was opened with, or `nil` if it isn't one of ours.
    static func videoID(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == videoHost,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let id = components.queryItems?.first(where: { $0.name == videoIDQueryItem })?.value,
            !id.isEmpty
        else { return nil }
        return id
    }
}
