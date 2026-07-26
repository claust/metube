import Foundation

/// Queries YouTube search via the InnerTube TV client.
///
/// Same `context` and Bearer token as the feed — only the endpoint and params differ.
/// Search returns its hits as shelves too, but a flat, relevance-ordered list is what a
/// results grid wants, so the shelf structure is deliberately discarded here.
struct SearchService {

    /// Runs a query and returns the first page of video results.
    ///
    /// Channels and playlists are dropped by the cell parser — this prototype can only play
    /// videos, so a card that leads nowhere is worse than one fewer result.
    func search(query: String, accessToken: String) async throws -> [VideoItem] {
        let json = try await InnerTubeClient.post(
            endpoint: "search",
            client: .tv,
            params: ["query": query],
            bearer: accessToken
        )
        let items = VideoItemParser.items(in: json)

        #if DEBUG
        print("[SearchService] \"\(query)\": \(items.count) results")
        #endif

        return items
    }
}
