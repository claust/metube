import Foundation
import SwiftUI

/// The cards behind the History screen: what each watched video *is*, kept per profile.
///
/// The list of what was watched, and when, is `WatchProgressStore` — a position, a duration and
/// a date per videoId, synced to the backend and restored on a fresh install. That is the right
/// record to build a history from, and it is also unusable on its own: a page of ids has nothing
/// to draw. So this holds the other half, a card per video, from wherever one has been seen:
///
///  - the video the player just started, which is the app holding a full card anyway;
///  - the account's own history list (`FEhistory`), which arrives as cards;
///  - `VideoMetadataService`, for the ids left over — looked up once and kept, because that
///    lookup is one request per video and there is no batch form of it.
///
/// `watchedAt` says the video was played *on this Apple TV*, which is the one thing the synced
/// progress can't tell us: a video watched here for under ten seconds records no position at
/// all, and should still be in the history. A card that is merely known — cached, never played
/// here — leaves it `nil`.
///
/// Kept in UserDefaults per profile, like watch progress and subscriptions: not a secret, cheap
/// to lose, and on disk it means the page draws the moment it opens instead of after a round of
/// lookups.
@MainActor
final class WatchHistoryStore: ObservableObject {

    /// One video's card, and when it was played here if it was.
    ///
    /// Its own type rather than a stored `VideoItem`, following `TopShelfVideo`: this is a
    /// format on disk, and a field added to the model a year from now must not make every
    /// previously stored entry undecodable.
    struct Entry: Codable, Hashable {
        let title: String
        let author: String
        let channelID: String?
        let thumbnailURL: URL?
        let publishedAt: Date?
        let viewCount: String
        let duration: String
        let isShort: Bool
        /// When this video was last played on this Apple TV, and `nil` for a card that is only
        /// cached — one from the account's history list, or a lookup for a video watched on
        /// another box.
        var watchedAt: Date?

        init(video: VideoItem, watchedAt: Date?) {
            title = video.title
            author = video.author
            channelID = video.channelID
            thumbnailURL = video.thumbnailURL
            publishedAt = video.publishedAt
            viewCount = video.viewCount
            duration = video.duration
            isShort = video.isShort
            self.watchedAt = watchedAt
        }

        /// The card again, for the grid to draw and the player to open.
        func video(id: String) -> VideoItem {
            VideoItem(
                id: id, title: title, author: author, channelID: channelID,
                thumbnailURL: thumbnailURL, publishedAt: publishedAt, viewCount: viewCount,
                duration: duration, isShort: isShort)
        }
    }

    /// By videoId — the page looks cards up by id, having got its order from somewhere else.
    @Published private(set) var entries: [String: Entry] = [:]

    private let defaults: UserDefaults
    /// Whose history is loaded, and `nil` when nobody is signed in.
    private var profileID: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Profiles

    /// Points the store at a profile's cards, replacing whatever was loaded. Pass `nil` when the
    /// last profile signs out, so the page can't keep showing the departed user's videos.
    func activate(profileID: String?) {
        guard profileID != self.profileID else { return }
        self.profileID = profileID
        entries = profileID.map(load(profileID:)) ?? [:]
    }

    /// Erases a profile's cards — used when the user signs that profile out. Watch progress is
    /// backed up and meant to survive that; this is only ever a local copy of what some feed
    /// already said, so there is nothing to keep.
    func discardEntries(for profileID: String) {
        defaults.removeObject(forKey: Self.storageKey(profileID: profileID))
        if profileID == self.profileID { entries = [:] }
    }

    /// Carries a profile's cards over when it changes id — which happens once, to the login
    /// migrated from the single-account build, as soon as we learn which account it is.
    func moveEntries(from oldID: String, to newID: String) {
        guard let data = defaults.data(forKey: Self.storageKey(profileID: oldID)) else { return }
        defaults.set(data, forKey: Self.storageKey(profileID: newID))
        defaults.removeObject(forKey: Self.storageKey(profileID: oldID))
    }

    // MARK: - Reading

    /// The card for a video, or `nil` when nothing here has ever seen it.
    func card(for videoId: String) -> VideoItem? {
        entries[videoId]?.video(id: videoId)
    }

    /// Videos played on this Apple TV, newest first. The synced progress covers all but the
    /// briefest of these; this is what keeps a video someone bailed out of after five seconds in
    /// the history all the same.
    var watchedHere: [(id: String, watchedAt: Date)] {
        entries.compactMap { id, entry in entry.watchedAt.map { (id, $0) } }
            .sorted { $0.1 > $1.1 }
    }

    // MARK: - Writing

    /// Records that a video is being watched here, now.
    ///
    /// Called when playback actually starts rather than when the card is pressed: a video that
    /// never resolved a stream was not watched, and a History page listing it would be reporting
    /// something that didn't happen.
    func record(_ video: VideoItem) {
        guard profileID != nil else { return }
        // A Top Shelf tile whose snapshot has been replaced arrives with nothing but an id: keep
        // whatever card the store already has for it rather than overwriting one with a blank.
        let card: Entry
        if video.title.isEmpty, let known = entries[video.id] {
            card = known
        } else {
            card = Entry(video: video, watchedAt: nil)
        }
        entries[video.id] = withWatchedAt(.now, on: card)
        persist()
    }

    /// Caches cards for videos we now know something about, without claiming they were watched
    /// here. Anything already stored keeps its own card unless the new one says more — a lookup
    /// that came back empty must not blank out what a feed had already supplied.
    func remember(_ videos: [VideoItem]) {
        guard profileID != nil else { return }
        var changed = false
        for video in videos where !video.title.isEmpty {
            let card = withWatchedAt(entries[video.id]?.watchedAt, on: Entry(video: video, watchedAt: nil))
            // A card that says exactly what the stored one says is not a change: the account's
            // history is re-fetched on every visit, and republishing it would redraw the grid and
            // rewrite the file for nothing.
            guard entries[video.id] != card else { continue }
            entries[video.id] = card
            changed = true
        }
        guard changed else { return }
        persist()
    }

    /// Drops cards for videos the history no longer has any reason to draw — everything that is
    /// neither watched here nor in the ids passed in, which is what the page is built from.
    ///
    /// This is the store's only bound. A count-based cap would be the wrong shape: the cards
    /// worth keeping are exactly the ones some *other* list still points at, and there is no
    /// number of them that is too many if every one is on the page.
    func prune(keeping ids: Set<String>) {
        let kept = entries.filter { id, entry in entry.watchedAt != nil || ids.contains(id) }
        guard kept.count != entries.count else { return }
        entries = kept
        persist()
    }

    private func withWatchedAt(_ date: Date?, on entry: Entry) -> Entry {
        var copy = entry
        copy.watchedAt = date
        return copy
    }

    // MARK: - Storage

    private static func storageKey(profileID: String) -> String { "yt.watchHistory.\(profileID)" }

    private func load(profileID: String) -> [String: Entry] {
        guard let data = defaults.data(forKey: Self.storageKey(profileID: profileID)),
            let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return decoded
    }

    /// Written inline rather than off the actor, unlike watch progress: this changes when a video
    /// starts or a lookup lands, not every few seconds of playback.
    private func persist() {
        guard let profileID, let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey(profileID: profileID))
    }
}
