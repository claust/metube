import Foundation

/// Which channel a video is from, for the cards whose feed cell didn't say.
///
/// Home's video tiles stopped carrying their channel in October 2026 (verified against a live
/// `browse` response, 2026-10-03). The id `VideoItemParser` reads lived in the tile's long-press
/// menu — a "Go to channel" item with a `browseEndpoint` — and that menu now arrives as a
/// `showEngagementPanelEndpoint` for `PAcontext_menu`, which YouTube's own client fetches when
/// Select is held, rather than with the tile. Subscriptions tiles and Shorts still carry theirs
/// inline. Without the id a card's menu has nothing to offer and its avatar can't be looked up.
///
/// So the gaps are filled by video id, through `VideoMetadataService`: `player` on the VISIONOS
/// client, whose `videoDetails.channelId` names the channel in ~150ms. A card asks when it takes
/// focus, so by the time Select has been held long enough for the menu the answer is usually
/// already here; the menu asks as well, for the card it was opened on, in case it isn't.
///
/// The lookups belong to the store rather than to whoever asked. Opening the menu takes focus
/// off the card, and a lookup that died with the card's focus would leave the menu waiting on
/// an answer nobody was fetching any more.
///
/// Kept in memory only. A Home feed turns over on every visit and an answer costs one quick
/// request, so a disk cache would mostly hold videos that are never shown again.
@MainActor
final class VideoChannelStore: ObservableObject {
    /// The `UC…` id each looked-up video belongs to, by videoId.
    @Published private(set) var channelIDs: [String: String] = [:]

    /// Lookups under way, by videoId. A lookup that comes back empty — the video has gone private
    /// or been deleted, or the request failed — leaves nothing behind, so the next ask tries again
    /// rather than a dropped connection marking the card for good.
    private var lookups: [String: Task<Void, Never>] = [:]

    /// `item` with its channel filled in, when the cell didn't carry one and a lookup has found
    /// it. Everything that acts on the channel — the menu, the avatar — reads the card through
    /// this.
    func resolved(_ item: VideoItem) -> VideoItem {
        guard item.channelID == nil, let channelID = channelIDs[item.id] else { return item }
        var copy = item
        copy.channelID = channelID
        return copy
    }

    /// Whether this video's channel is being looked up right now.
    func isLookingUp(_ item: VideoItem) -> Bool { lookups[item.id] != nil }

    /// Starts finding the channel, without waiting for it. Free for a card that already knows its
    /// channel, and for one whose lookup is already under way.
    func prefetch(_ item: VideoItem) {
        guard resolved(item).channelID == nil, lookups[item.id] == nil else { return }

        let videoID = item.id
        lookups[videoID] = Task {
            if let channelID = try? await VideoMetadataService().load(videoId: videoID)?.channelID {
                channelIDs[videoID] = channelID
            }
            lookups[videoID] = nil
        }
    }
}
