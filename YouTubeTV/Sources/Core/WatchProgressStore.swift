import Foundation
import SwiftUI

/// Remembers how far into each video the user got, so playback resumes where they left off
/// and the feed can draw a progress line under the thumbnail.
///
/// Persisted in UserDefaults rather than the Keychain: a playback position is not a secret,
/// and unlike the OAuth tokens it is cheap to lose. Injected as an @EnvironmentObject so cards
/// redraw as soon as the player writes a new position.
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
    private let storageKey = "yt.watchProgress"
    /// The write in flight, so the next one can queue behind it (see `persist`).
    private var persistTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        {
            entries = decoded
        }
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
        guard position.isFinite, position >= Self.minimumPosition else { return }
        guard duration.isFinite, duration > 0 else { return }
        let reached = position >= duration - Self.endThreshold ? duration : position
        entries[videoId] = Entry(position: reached, duration: duration, updatedAt: Date())
        persist()
    }

    /// Marks the video as watched through — a full red line on the card, and playback that
    /// starts over next time.
    func markFinished(videoId: String, duration: TimeInterval) {
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
        let snapshot = entries
        let defaults = defaults
        let key = storageKey
        let previous = persistTask
        persistTask = Task.detached(priority: .utility) {
            await previous?.value
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
