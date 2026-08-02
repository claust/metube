import Foundation

/// One channel the account follows, as the Subscriptions screen shows it.
///
/// Read off the `FEchannels` grid — see `SubscribedChannelParser` — which is the only place
/// YouTube hands over the whole list in one reply. Everything but the id is best-effort: the
/// cells are not a documented shape and vary by client, so a channel that arrives with nothing
/// but its id is still a channel worth listing (its page knows its own name).
struct SubscribedChannel: Identifiable, Hashable {
    /// The `UC…` id, and what the channel page is opened by.
    let id: String
    /// The channel's name, empty when the cell carried none.
    let title: String
    /// The channel's picture, `nil` when the cell carried none — in which case the screen looks
    /// it up through `ChannelAvatarStore`, the same cache the feed's cards draw from.
    let avatarURL: URL?
    /// Whatever the cell said about the channel besides its name — "1.2M subscribers",
    /// "342 videos". Shown verbatim: it arrives as display text, already abbreviated, and is
    /// empty when the cell carried neither.
    let detail: String

    /// What to put on the tile. A nameless channel still gets a tile rather than being dropped:
    /// its picture is usually recognisable, and opening it fills in the rest.
    var displayName: String { title.isEmpty ? "Unknown channel" : title }

    init(id: String, title: String = "", avatarURL: URL? = nil, detail: String = "") {
        self.id = id
        self.title = title
        self.avatarURL = avatarURL
        self.detail = detail
    }
}

/// What one `FEchannels` response yields: every channel the account follows, and the bare set of
/// ids behind it.
///
/// The two are parsed by different routes on purpose. The ids come from a plain walk for `UC…`
/// browse endpoints, which cannot miss a channel whatever cell shape it arrived in — and they are
/// what the card menus' Subscribe/Unsubscribe labels ride on, so being complete matters more than
/// being detailed. The channels come from reading recognised cells, which yields names and
/// pictures but only for shapes this app knows.
struct SubscriptionListing {
    let channelIDs: Set<String>
    let channels: [SubscribedChannel]
}
