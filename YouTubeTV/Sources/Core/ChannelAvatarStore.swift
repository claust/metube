import Foundation

/// The channel pictures the cards draw, and the cache behind them.
///
/// The TV feed's video cells carry no avatar of their own (verified against a live `browse`
/// response, 2026-07-27) — only the video thumbnail — so every picture here is looked up. Two
/// sources feed it, cheapest first:
///
/// 1. The **Subscriptions** response, whose channel filter bar lists everyone you follow with
///    their picture. One request the app already makes covers a hundred channels, but it names
///    them without giving their ids, so those land keyed by name.
/// 2. A **per-channel `browse`**, for everything else the feed mixes in. One request per
///    channel, keyed by the `UC…` id off the video cell, and asked at most once ever: the
///    answers are written to the caches directory and read back on the next launch.
///
/// Both maps are consulted for every card, id first — a name is a weak key (two channels can
/// share a display name) but it's free, and it's all source 1 gives.
@MainActor
final class ChannelAvatarStore: ObservableObject {
    @Published private(set) var byID: [String: URL] = [:]
    @Published private(set) var byName: [String: URL] = [:]

    /// Channels being looked up right now, so a row of cards for one channel asks once.
    private var inFlight: Set<String> = []
    /// Channels whose lookup failed. Not persisted: a failure is usually the network, and the
    /// next launch deserves a fresh try. Retrying within a session isn't worth 200KB a card.
    private var failed: Set<String> = []

    /// A pending write of the cache, coalesced so a burst of lookups doesn't write the file
    /// once per channel.
    private var saveTask: Task<Void, Never>?

    private let cacheFile: URL
    /// When each entry in `byID` was looked up, so re-saving the cache doesn't keep resetting
    /// the clock on entries that have been sitting in it for weeks.
    private var fetchedAt: [String: Date] = [:]

    /// Long enough that channels aren't re-fetched in any normal use, short enough that a
    /// channel that rebrands catches up eventually.
    private static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    init(cacheFile: URL? = nil) {
        self.cacheFile =
            cacheFile
            ?? URL.cachesDirectory.appendingPathComponent("channel-avatars.json")
        let cached = Self.loadCache(from: self.cacheFile)
        byID = cached.mapValues(\.url)
        fetchedAt = cached.mapValues(\.fetchedAt)
    }

    // MARK: - Reading

    /// The picture to draw for a video, or `nil` while it's still unknown. Cards call this on
    /// every redraw, so it only reads — `resolve(_:)` is what goes and finds a missing one.
    func url(for item: VideoItem) -> URL? {
        if let embedded = item.channelAvatarURL { return embedded }
        if let id = item.channelID, let url = byID[id] { return url }
        return byName[Self.key(item.author)]
    }

    /// The picture for a channel known by its id alone — the Subscriptions screen's tiles, which
    /// have no video cell to have carried one.
    func url(forChannel channelID: String) -> URL? { byID[channelID] }

    /// Fetches this video's channel picture if it isn't known yet. Safe to call from every
    /// card on every appearance: known channels, in-flight ones and ones already tried return
    /// immediately.
    func resolve(_ item: VideoItem) async {
        // The name-keyed half of the cache counts as knowing it, which is why this is asked
        // before the id — a channel pictured by the Subscriptions feed costs no lookup at all.
        guard url(for: item) == nil, let id = item.channelID else { return }
        await resolve(channelID: id)
    }

    /// The same lookup for a bare channel id. Equally safe to call on every redraw.
    func resolve(channelID id: String) async {
        guard byID[id] == nil else { return }
        guard !inFlight.contains(id), !failed.contains(id) else { return }

        inFlight.insert(id)
        defer { inFlight.remove(id) }

        do {
            guard let url = try await ChannelAvatarService.fetchAvatarURL(forChannel: id) else {
                failed.insert(id)
                return
            }
            byID[id] = url
            fetchedAt[id] = Date()
            scheduleSave()
        } catch {
            // A card scrolling out of view cancels its lookup. That's not a failure — blacklisting
            // on it would leave a channel blank for the rest of the session after one fast scroll.
            if isCancellation(error) { return }
            failed.insert(id)
        }
    }

    // MARK: - Writing

    /// Adds the name-keyed pictures a feed response yielded. Later feeds only fill gaps: the
    /// pictures don't change between responses, and rewriting the dictionary would republish it
    /// for no visible gain.
    func merge(_ found: [String: URL]) {
        for (name, url) in found where byName[Self.key(name)] == nil {
            byName[Self.key(name)] = url
        }
    }

    /// Case and surrounding space differ between the filter bar and the cells often enough to
    /// matter, so both sides go through this.
    private static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Disk cache

    /// One cached lookup. The date is what expiry is judged on; without it a stale picture
    /// would outlive the app.
    private struct Entry: Codable {
        let url: URL
        let fetchedAt: Date
    }

    private static func loadCache(from file: URL) -> [String: Entry] {
        guard let data = try? Data(contentsOf: file),
            let entries = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }

        let cutoff = Date().addingTimeInterval(-maxAge)
        return entries.filter { $0.value.fetchedAt > cutoff }
    }

    /// Writes the cache a moment after the last change. Lookups arrive in bursts — a screenful
    /// of cards at once — and this turns that into one write.
    private func scheduleSave() {
        saveTask?.cancel()
        let now = Date()
        var entries: [String: Entry] = [:]
        for (id, url) in byID {
            entries[id] = Entry(url: url, fetchedAt: fetchedAt[id] ?? now)
        }
        let file = cacheFile
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            guard let data = try? JSONEncoder().encode(entries) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }
}
