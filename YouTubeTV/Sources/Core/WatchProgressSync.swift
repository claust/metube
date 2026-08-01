import Foundation
import SwiftUI

/// Keeps a profile's watch history on the Appwrite backend, so reinstalling the app — or
/// watching on a second Apple TV — doesn't start from nothing.
///
/// Strictly local-first. `WatchProgressStore` remains the single source of truth for what the
/// feed and the player see; this only pushes what's there and folds in what came back. Every
/// failure is swallowed: the backend being unreachable must cost nothing more than the sync
/// itself, and an app that can't reach a home server on a domestic connection is a normal
/// Tuesday.
///
/// There is no login screen because there is no login. The YouTube sign-in the app already
/// performs is proof of identity; `Backend/functions/metube-auth` turns it into an Appwrite
/// session. See `Backend/README.md`.
@MainActor
final class WatchProgressSync: ObservableObject {

    /// How long a burst of local writes is allowed to settle before it is pushed. The player
    /// records a position every five seconds, so pushing on each one would put a request on
    /// the network for every tick of a video.
    private static let flushDelay: Duration = .seconds(15)

    /// Rows per page when pulling. Appwrite's own ceiling is higher; this keeps a large
    /// history from arriving as one long request on a connection that may not want it.
    private static let pageSize = 100

    /// Everything the sync needs about the profile it is syncing: which local history it
    /// belongs to, and the two values `metube-auth` turns into an Appwrite session.
    private struct Target {
        let id: String
        let accountKey: String
        let accessToken: String
    }

    private let store: WatchProgressStore
    private let defaults: UserDefaults

    /// The profile being synced. `nil` while signed out, which is also what stops any of this
    /// from running.
    private var profile: Target?
    private var client: AppwriteClient?

    /// The debounced push, and the pull/flush currently running. Held so a profile switch can
    /// cancel work that belongs to the profile being switched away from.
    private var flushTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    /// The sign-in in flight, so concurrent callers wait on it rather than starting their own.
    private var signInTask: Task<String?, Never>?

    init(store: WatchProgressStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        store.onLocalChange = { [weak self] in self?.scheduleFlush() }
    }

    // MARK: - Lifecycle

    /// Points the sync at a profile, then pulls and pushes once. Pass `nil` when the last
    /// profile signs out.
    ///
    /// The account key is what the backend verifies the YouTube token against, so a profile
    /// whose account hasn't been identified yet can't sync — it will on the next activation,
    /// once `backfillAccountInfo` has run.
    func activate(profile: Profile?, accessToken: String?) {
        flushTask?.cancel()
        runTask?.cancel()

        guard let profile, let accountKey = profile.accountKey, let accessToken else {
            self.profile = nil
            client = nil
            return
        }
        self.profile = Target(id: profile.id, accountKey: accountKey, accessToken: accessToken)
        client = AppwriteClient(session: storedSession(for: profile.id))
        sync()
    }

    /// Pulls anything new and pushes anything queued. Called on profile activation and when
    /// the app returns to the foreground, where a second box may have moved on without us.
    func sync() {
        guard profile != nil, client != nil else { return }
        runTask?.cancel()
        runTask = Task { [weak self] in
            await self?.pull()
            await self?.push()
        }
    }

    /// Pushes now rather than waiting out the debounce — on the way to the background, and
    /// when the player closes, which are the two moments where "later" may never come.
    func flushNow() {
        flushTask?.cancel()
        guard profile != nil, client != nil, !store.dirty.isEmpty else { return }
        // Cancelled, not merely replaced: dropping the reference to a running pull would leave
        // it uncancellable by a later profile switch, and two pushes overlapping would upload
        // the same rows twice.
        runTask?.cancel()
        runTask = Task { [weak self] in await self?.push() }
    }

    private func scheduleFlush() {
        guard profile != nil, client != nil else { return }
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flushDelay)
            guard !Task.isCancelled else { return }
            await self?.push()
        }
    }

    // MARK: - Session

    /// The session for a profile, or `nil` until it has one. Kept in the Keychain rather than
    /// UserDefaults for the same reason the OAuth tokens are: it authenticates requests.
    private func storedSession(for profileID: String) -> AppwriteClient.Session? {
        guard let raw = KeychainStore.get(Self.sessionKey(profileID: profileID)),
            let data = raw.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(AppwriteClient.Session.self, from: data)
    }

    private func persist(session: AppwriteClient.Session?, for profileID: String) {
        guard let session, let data = try? JSONEncoder().encode(session) else {
            KeychainStore.delete(Self.sessionKey(profileID: profileID))
            return
        }
        KeychainStore.set(String(data: data, encoding: .utf8), for: Self.sessionKey(profileID: profileID))
    }

    private static func sessionKey(profileID: String) -> String { "appwrite.session.\(profileID)" }

    /// Signs in if there is no session yet. Returns the session's user id, which every row is
    /// keyed and permissioned by.
    ///
    /// Callers wait on a sign-in already in flight rather than starting a second: a pull and a
    /// push kicked off together would otherwise both find no session, and two sign-ins racing
    /// each other is two Appwrite users being created for one account.
    private func authenticate() async -> String? {
        guard let profile, let client else { return nil }
        if let session = client.session { return session.userId }
        if let signInTask { return await signInTask.value }

        let task = Task { [weak self] () -> String? in
            do {
                let session = try await client.signIn(
                    accessToken: profile.accessToken, accountKey: profile.accountKey)
                await self?.adopt(session: session, for: profile.id)
                return session.userId
            } catch {
                await self?.log("sign-in failed: \(error.localizedDescription)")
                return nil
            }
        }
        signInTask = task
        let userId = await task.value
        signInTask = nil
        return userId
    }

    private func adopt(session: AppwriteClient.Session, for profileID: String) {
        guard profile?.id == profileID else { return }
        client?.session = session
        persist(session: session, for: profileID)
    }

    /// Throws away a session Appwrite no longer recognises, so the next attempt signs in
    /// afresh. Sessions do expire, and a project that has been rebuilt invalidates every one.
    private func invalidateSession() {
        guard let profile else { return }
        client?.session = nil
        persist(session: nil, for: profile.id)
    }

    // MARK: - Pull

    /// Folds in everything the backend has learned since the last pull.
    ///
    /// Incremental by `watchedAt` rather than a full download: the history is unbounded and
    /// grows for as long as the account is used, and after the first sync almost none of it
    /// has changed.
    private func pull() async {
        guard let profile, let userId = await authenticate(), let client else { return }
        // Re-read after the await: a profile switch may have landed while signing in, and the
        // rows about to arrive belong to the profile that asked for them.
        guard self.profile?.id == profile.id else { return }

        let since = defaults.string(forKey: Self.pulledAtKey(profileID: profile.id))
        var cursor: String?
        var latest = since
        var merged: [String: WatchProgressStore.Entry] = [:]

        while !Task.isCancelled {
            guard let rows = await page(from: client, userId: userId, since: since, after: cursor)
            else { return }

            latest = Self.fold(rows, into: &merged) ?? latest
            guard rows.count == Self.pageSize, let last = rows.last?["$id"] as? String else { break }
            cursor = last
        }

        guard !Task.isCancelled, self.profile?.id == profile.id else { return }
        log("pulled \(merged.count) row(s); since=\(since ?? "never"); local=\(store.entries.count)")
        if !merged.isEmpty { store.merge(remote: merged) }
        // Nothing had ever been pulled, so nothing has ever been pushed either: whatever this
        // device already knows is owed to the backend. Everything watched before syncing
        // existed — or while it couldn't reach the server — goes up on this first run.
        if since == nil { store.queueAll(except: Set(merged.keys)) }
        if let latest { defaults.set(latest, forKey: Self.pulledAtKey(profileID: profile.id)) }
    }

    /// Adds a page's rows to `merged`, and returns the newest `watchedAt` it carried — the
    /// high-water mark the next pull resumes from. `nil` for a page that contributed nothing.
    private static func fold(
        _ rows: [[String: Any]],
        into merged: inout [String: WatchProgressStore.Entry]
    ) -> String? {
        var latest: String?
        for row in rows {
            guard let videoId = row["videoId"] as? String, let entry = entry(from: row) else { continue }
            merged[videoId] = entry
            // The rows arrive ordered by `watchedAt`, so the last one wins.
            latest = row["watchedAt"] as? String ?? latest
        }
        return latest
    }

    /// One page of a profile's rows, or `nil` when the request failed — which ends the pull
    /// rather than skipping a page, since a gap would be recorded as successfully caught up.
    private func page(
        from client: AppwriteClient,
        userId: String,
        since: String?,
        after cursor: String?
    ) async -> [[String: Any]]? {
        var queries = [
            AppwriteQuery.equal("userId", userId),
            AppwriteQuery.orderAsc("watchedAt"),
            AppwriteQuery.limit(Self.pageSize),
        ]
        if let since { queries.append(AppwriteQuery.greaterThan("watchedAt", since)) }
        if let cursor { queries.append(AppwriteQuery.cursorAfter(cursor)) }

        do {
            return try await client.listRows(
                databaseID: AppConfig.appwriteDatabaseID,
                tableID: AppConfig.appwriteWatchProgressTableID,
                queries: queries
            )
        } catch AppwriteError.unauthorized(let message) {
            log("session rejected: \(message ?? "no reason given")")
            invalidateSession()
            return nil
        } catch {
            log("pull failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// A row as the store holds it, or `nil` for one missing a field it can't be reconstructed
    /// without — which shouldn't happen, every column being required, but a malformed row is
    /// not worth abandoning the rest of the page over.
    private static func entry(from row: [String: Any]) -> WatchProgressStore.Entry? {
        guard let position = row["position"] as? Double,
            let duration = row["duration"] as? Double,
            let watchedAt = row["watchedAt"] as? String,
            let updatedAt = date(from: watchedAt)
        else { return nil }
        return .init(position: position, duration: duration, updatedAt: updatedAt)
    }

    private static func pulledAtKey(profileID: String) -> String { "yt.watchProgress.pulledAt.\(profileID)" }

    // MARK: - Push

    /// Uploads every queued entry, one row at a time.
    ///
    /// Sequential on purpose: the queue is normally a handful of videos, and a home server on
    /// the far side of a domestic uplink is happier with one request at a time than with a
    /// burst. A row that fails stays queued and goes again on the next flush.
    private func push() async {
        guard let profile, let userId = await authenticate(), let client else { return }
        guard self.profile?.id == profile.id else { return }

        // Snapshotted rather than read through `store` each time round: playback can queue more
        // videos while this loop is awaiting the network, and those belong to the next flush.
        let queued = store.dirty
        var pushed: [String: Date] = [:]
        for videoId in queued {
            guard !Task.isCancelled else { break }
            guard let entry = store.entries[videoId] else { continue }
            do {
                try await client.upsertRow(
                    databaseID: AppConfig.appwriteDatabaseID,
                    tableID: AppConfig.appwriteWatchProgressTableID,
                    rowID: "\(profile.id)_\(videoId)",
                    data: [
                        "userId": userId,
                        "videoId": videoId,
                        "position": entry.position,
                        "duration": entry.duration,
                        "watchedAt": Self.string(from: entry.updatedAt),
                    ],
                    // Row security is on, so this is what keeps one profile's history out of
                    // another's — including on a shared Apple TV.
                    permissions: [
                        "read(\"user:\(userId)\")",
                        "update(\"user:\(userId)\")",
                        "delete(\"user:\(userId)\")",
                    ]
                )
                pushed[videoId] = entry.updatedAt
            } catch AppwriteError.unauthorized(let message) {
                log("session rejected: \(message ?? "no reason given")")
                invalidateSession()
                break
            } catch {
                log("push of \(videoId) failed: \(error.localizedDescription)")
                break
            }
        }

        log("pushed \(pushed.count) of \(store.dirty.count) queued")
        guard self.profile?.id == profile.id, !pushed.isEmpty else { return }
        store.markSynced(pushed)
    }

    // MARK: - Dates

    /// Appwrite datetimes are ISO 8601 with fractional seconds, which is not the format
    /// `ISO8601DateFormatter` parses by default.
    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func date(from string: String) -> Date? {
        iso.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private static func string(from date: Date) -> String { iso.string(from: date) }

    private func log(_ message: String) {
        #if DEBUG
        print("[WatchProgressSync] \(message)")
        #endif
    }
}
