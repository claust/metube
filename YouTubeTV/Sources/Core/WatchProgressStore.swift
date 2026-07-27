import Foundation
import SwiftUI

/// Remembers how far into each video the user got, so playback resumes where they left off
/// and the feed can draw a progress line under the thumbnail.
///
/// Persisted in UserDefaults rather than the Keychain: a playback position is not a secret,
/// and unlike the OAuth tokens it is cheap to lose. Injected as an @EnvironmentObject so cards
/// redraw as soon as the player writes a new position.
///
/// History belongs to a profile, not to the device, so entries are stored under a per-profile
/// key and the store is pointed at the active one with `activate(profileID:)`. With no profile
/// active there is nothing to read and nowhere to write.
@MainActor
final class WatchProgressStore: ObservableObject {

    /// One video's position on the timeline, with the duration it was measured against —
    /// the feed only ever gets the duration as display text ("21:55"), and the player's own
    /// figure is the accurate one.
    struct Entry: Codable, Hashable {
        var position: TimeInterval
        var duration: TimeInterval
        var updatedAt: Date
    }

    @Published private(set) var entries: [String: Entry] = [:]

    /// Below this a video counts as "opened", not "watched" — resuming a few seconds in is
    /// more annoying than starting over, and a sliver of a bar reads as noise.
    private static let minimumPosition: TimeInterval = 10

    /// Within this of the end the video counts as finished: the position is pinned to the
    /// duration, so the card keeps a full red line but a replay starts from the beginning
    /// rather than the credits.
    private static let endThreshold: TimeInterval = 20

    private let defaults: UserDefaults
    /// Whose history is loaded, and `nil` when nobody is signed in.
    private var profileID: String?
    /// The write in flight, so the next one can queue behind it (see `persist`).
    private var persistTask: Task<Void, Never>?

    /// Bumped whenever the stored history is rearranged behind the writer's back — a profile
    /// switch, the legacy migration, a move, a deletion. A persist queued before the bump holds
    /// a snapshot of a history that no longer belongs at that key, so it is dropped instead of
    /// written: without this, signing a profile out could be undone moments later by a write
    /// that was already on its way to disk.
    ///
    /// A counter rather than a per-profile "deleted" flag, because there is nothing to clear:
    /// a profile signed out and back in simply persists at the newer generation.
    private var generation = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Profiles

    /// Points the store at a profile's history, replacing whatever was loaded. Pass `nil` when
    /// the last profile signs out, so the feed can't keep drawing the departed user's progress.
    func activate(profileID: String?) {
        guard profileID != self.profileID else { return }
        generation += 1
        self.profileID = profileID
        entries = profileID.map { load(profileID: $0) } ?? [:]
    }

    /// Key under which one profile's history is stored, kept in one place so the migration and
    /// deletion helpers agree with `persist`.
    private static func storageKey(profileID: String) -> String { "yt.watchProgress.\(profileID)" }

    private func load(profileID: String) -> [String: Entry] {
        guard let data = defaults.data(forKey: Self.storageKey(profileID: profileID)),
            let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return decoded
    }

    /// Hands the pre-profiles build's single, un-namespaced history to the profile its login
    /// became. Does nothing once that profile has a history of its own, so a rerun can't
    /// resurrect stale entries over newer ones.
    func adoptLegacyEntries(for profileID: String) {
        let legacyKey = "yt.watchProgress"
        guard let data = defaults.data(forKey: legacyKey) else { return }
        if defaults.data(forKey: Self.storageKey(profileID: profileID)) == nil {
            defaults.set(data, forKey: Self.storageKey(profileID: profileID))
        }
        defaults.removeObject(forKey: legacyKey)
        generation += 1
    }

    /// Carries a profile's history over when it changes id — which happens once, to the login
    /// migrated from the single-account build, as soon as we learn which account it is.
    func moveEntries(from oldID: String, to newID: String) {
        guard let data = defaults.data(forKey: Self.storageKey(profileID: oldID)) else { return }
        defaults.set(data, forKey: Self.storageKey(profileID: newID))
        defaults.removeObject(forKey: Self.storageKey(profileID: oldID))
        generation += 1
    }

    /// Erases a profile's history — used when the user signs that profile out for good.
    func discardEntries(for profileID: String) {
        defaults.removeObject(forKey: Self.storageKey(profileID: profileID))
        generation += 1
    }

    // MARK: - Reading

    /// Where playback should resume for `videoId`, or `nil` to start from the beginning —
    /// which is also what a finished video gets, so replaying one doesn't drop into the credits.
    func resumePosition(for videoId: String) -> TimeInterval? {
        guard let entry = entries[videoId], entry.position >= Self.minimumPosition, !isFinished(entry)
        else { return nil }
        return entry.position
    }

    /// How far through the video the user is, 0...1, or `nil` when there's nothing to draw.
    func fraction(for item: VideoItem) -> Double? {
        guard let entry = entries[item.id], entry.position >= Self.minimumPosition, entry.duration > 0
        else { return nil }
        return min(1, entry.position / entry.duration)
    }

    // MARK: - Writing

    /// Records where playback has reached. A position inside the end threshold is pinned to the
    /// duration, so the last stretch of a video reads as watched through rather than as a bar
    /// that never quite fills.
    ///
    /// A video with no duration from either the player or the feed tile records nothing: it is
    /// a live stream, where "where you left off" has no meaning and no fraction could be drawn.
    func record(videoId: String, position: TimeInterval, duration: TimeInterval) {
        guard profileID != nil else { return }
        guard position.isFinite, position >= Self.minimumPosition else { return }
        guard duration.isFinite, duration > 0 else { return }
        let reached = position >= duration - Self.endThreshold ? duration : position
        entries[videoId] = Entry(position: reached, duration: duration, updatedAt: Date())
        persist()
    }

    /// Marks the video as watched through — a full red line on the card, and playback that
    /// starts over next time.
    func markFinished(videoId: String, duration: TimeInterval) {
        guard profileID != nil else { return }
        let known = duration.isFinite && duration > 0 ? duration : (entries[videoId]?.duration ?? 0)
        // With no duration from anywhere there is no fraction to draw, so there is nothing
        // meaningful to store either.
        guard known > 0 else { return }
        entries[videoId] = Entry(position: known, duration: known, updatedAt: Date())
        persist()
    }

    private func isFinished(_ entry: Entry) -> Bool {
        entry.duration > 0 && entry.position >= entry.duration - Self.endThreshold
    }

    // MARK: - Storage

    /// Encodes and writes off the main actor. The history is unbounded and playback rewrites it
    /// every few seconds, so doing this inline would put a cost that grows with the user's
    /// watch history on the same actor that drives the feed's scrolling.
    /// Writes are chained rather than merely detached: two overlapping tasks could otherwise
    /// finish out of order and leave the older snapshot on disk.
    private func persist() {
        // Captured now, not inside the task: by the time it runs the user may have switched
        // profiles, and this snapshot belongs to the one that was active when it was taken.
        guard let profileID else { return }
        let snapshot = entries
        let defaults = defaults
        let key = Self.storageKey(profileID: profileID)
        let generation = generation
        let previous = persistTask
        persistTask = Task.detached(priority: .utility) { [weak self] in
            await previous?.value
            // Checked here rather than at the top: this task can sit behind others for as long
            // as they take, and the sign-out it must not undo can land at any point in between.
            guard let self, await self.generation == generation else { return }
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            defaults.set(data, forKey: key)
        }
    }
}

extension VideoItem {
    /// The tile's duration text ("21:55", "1:02:14") as seconds, or `nil` when the feed gave
    /// none — live streams, and anything InnerTube left unlabelled.
    var durationSeconds: TimeInterval? {
        let parts = duration.split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count) else { return nil }
        var total: TimeInterval = 0
        for part in parts {
            guard let value = Int(part) else { return nil }
            total = total * 60 + TimeInterval(value)
        }
        return total
    }
}
