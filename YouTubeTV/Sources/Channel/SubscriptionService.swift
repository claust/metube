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
        let ordered = channelIDsInOrder(in: json)

        // A response whose cells this app doesn't recognise still yields ids, so fall back to
        // listing those bare: a grid of pictures looked up per channel, with the names filled in
        // by the pages behind them, beats a screen that says you subscribe to nothing. Only when
        // there is nothing at all to fall back from — the ids are a broader read than the cells
        // (a "recommended channels" shelf links channels too), so topping up a list that parsed
        // fine would put channels on the screen the account doesn't follow.
        //
        // In the order they appear in the reply, which is the order the cells would have given —
        // the screen puts them on a grid, and a grid ordered by channel id is a grid in no order
        // at all.
        let parsed = SubscribedChannelParser.channels(in: json)
        let channels = parsed.isEmpty ? ordered.map { SubscribedChannel(id: $0) } : parsed
        let ids = Set(ordered)

        #if DEBUG
        print(
            "[SubscriptionService] FEchannels: \(ids.count) subscribed channels"
                + " | \(channels.count) parsed as cells"
                + " | \(channels.filter { $0.title.isEmpty }.count) unnamed"
        )
        #endif

        return SubscriptionListing(channelIDs: ids, channels: channels)
    }

    /// Every `UC…` browse id in the response, first occurrence first.
    ///
    /// Order follows the arrays the cells sit in, which is the order YouTube wants them shown in.
    /// Between two branches of the same dictionary there is no document order to follow, so the
    /// walk takes them by sorted key — arbitrary, but the same on every run, which is what keeps
    /// the fallback grid from rearranging itself between two identical responses. (This is why it
    /// is written out rather than left to `findAllRenderers`, which walks a dictionary in
    /// whatever order it hands its keys over in.)
    private func channelIDsInOrder(in json: [String: Any]) -> [String] {
        var ids: [String] = []
        var seen: Set<String> = []

        func walk(_ obj: Any) {
            if let dict = obj as? [String: Any] {
                if let id = dict.string(at: "browseEndpoint/browseId"), id.hasPrefix("UC"),
                    seen.insert(id).inserted
                {
                    ids.append(id)
                }
                for key in dict.keys.sorted() { walk(dict[key] as Any) }
            } else if let array = obj as? [Any] {
                for value in array { walk(value) }
            }
        }
        walk(json)

        return ids
    }
}
