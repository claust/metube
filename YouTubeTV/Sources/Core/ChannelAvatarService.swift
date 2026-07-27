import Foundation

/// Looks up one channel's profile picture.
///
/// A `browse` on the channel's own id returns its page, whose `channelHeaderRenderer` carries
/// the avatar (and the banner, which is why this reads the avatar by path rather than by URL
/// host — both are served from the same place).
///
/// Unauthenticated on purpose: a channel page is public, so this doesn't need the user's token
/// and can't be what expires it. The reply is ~200KB for one small URL, which is why
/// `ChannelAvatarStore` caches the answer to disk and asks at most once per channel.
enum ChannelAvatarService {

    /// The avatar for a `UC…` channel id, or `nil` if the page had no header to read it from.
    static func fetchAvatarURL(forChannel channelID: String) async throws -> URL? {
        let json = try await InnerTubeClient.post(
            endpoint: "browse",
            client: .tv,
            params: ["browseId": channelID]
        )
        for header in findAllRenderers(named: "channelHeaderRenderer", in: json) {
            guard let thumbs = header.value(at: "avatar/thumbnails") as? [[String: Any]] else {
                continue
            }
            if let url = avatarURL(from: thumbs) { return url }
        }
        return nil
    }
}
