import Foundation

/// Subscribing and unsubscribing, and reading back which channels the account follows.
///
/// All three calls go to the same TVHTML5 client and Bearer token the feeds use. The two
/// mutations are the InnerTube `subscription/subscribe` and `subscription/unsubscribe`
/// endpoints, which take a list of channel ids — this app only ever sends one.
struct SubscriptionService {

    /// Follows the channel. Throws on anything but a 2xx, which is all the caller needs: the
    /// response body carries only the button's new label and tracking params.
    func subscribe(channelID: String, accessToken: String) async throws {
        _ = try await InnerTubeClient.post(
            endpoint: "subscription/subscribe",
            client: .tv,
            params: ["channelIds": [channelID]],
            bearer: accessToken
        )
    }

    func unsubscribe(channelID: String, accessToken: String) async throws {
        _ = try await InnerTubeClient.post(
            endpoint: "subscription/unsubscribe",
            client: .tv,
            params: ["channelIds": [channelID]],
            bearer: accessToken
        )
    }

    /// Every channel the account is subscribed to, as ids.
    ///
    /// `FEchannels` is the "All subscriptions" browse feed — a grid of the user's channels and
    /// nothing else, which is why the ids can be taken from the whole response rather than from
    /// a named container. Anything that isn't channel-shaped is filtered out by the same "UC"
    /// prefix test the cell parser uses.
    func loadSubscribedChannelIDs(accessToken: String) async throws -> Set<String> {
        let json = try await InnerTubeClient.post(
            endpoint: "browse",
            client: .tv,
            params: ["browseId": "FEchannels"],
            bearer: accessToken
        )
        var ids: Set<String> = []
        for endpoint in findAllRenderers(named: "browseEndpoint", in: json) {
            guard let id = endpoint["browseId"] as? String, id.hasPrefix("UC") else { continue }
            ids.insert(id)
        }

        #if DEBUG
        print("[SubscriptionService] FEchannels: \(ids.count) subscribed channels")
        #endif

        return ids
    }
}
