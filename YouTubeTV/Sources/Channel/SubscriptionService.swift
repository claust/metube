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

    /// Every channel the account is subscribed to: the ids the card menus label themselves from,
    /// and the named, pictured channels the Subscriptions screen lists.
    ///
    /// `FEchannels` is the "All subscriptions" browse feed — a grid of the user's channels and
    /// nothing else, which is why the ids can be taken from the whole response rather than from
    /// a named container. Anything that isn't channel-shaped is filtered out by the same "UC"
    /// prefix test the cell parser uses.
    ///
    /// Both halves come out of the one request, since they are two readings of the same reply —
    /// see `SubscriptionListing` for why they are read by different routes.
    func loadSubscriptions(accessToken: String) async throws -> SubscriptionListing {
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

        // A response whose cells this app doesn't recognise still yields ids, so fall back to
        // listing those bare: a grid of pictures looked up per channel, with the names filled in
        // by the pages behind them, beats a screen that says you subscribe to nothing. Only when
        // there is nothing at all to fall back from — the ids are a broader read than the cells
        // (a "recommended channels" shelf links channels too), so topping up a list that parsed
        // fine would put channels on the screen the account doesn't follow.
        let parsed = SubscribedChannelParser.channels(in: json)
        let channels = parsed.isEmpty ? ids.sorted().map { SubscribedChannel(id: $0) } : parsed

        #if DEBUG
        print(
            "[SubscriptionService] FEchannels: \(ids.count) subscribed channels"
                + " | \(channels.count) parsed as cells"
                + " | \(channels.filter { $0.title.isEmpty }.count) unnamed"
        )
        #endif

        return SubscriptionListing(channelIDs: ids, channels: channels)
    }
}
