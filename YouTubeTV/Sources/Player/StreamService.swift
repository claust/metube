import Foundation

/// Errors surfaced while resolving a playable stream URL, or while getting it to start.
enum StreamError: LocalizedError {
    case notPlayable(String)
    case noStream
    /// Resolved and handed to AVFoundation, but playback never got going — see
    /// `PlayerView.awaitPlaybackStart`.
    case stalled

    var errorDescription: String? {
        switch self {
        case .notPlayable(let reason):
            return reason.isEmpty
                ? "This video can't be played."
                : "This video can't be played: \(reason)"
        case .noStream:
            return "No playable stream was found for this video."
        case .stalled:
            return "This video's stream didn't start playing."
        }
    }
}

/// A stream ready to hand to AVFoundation.
struct ResolvedStream {
    let url: URL
    /// The client that minted this URL. Handed back to `resolveStream(videoId:after:)` if the
    /// stream turns out not to play, so the ladder can pick up at the next one.
    let client: AppConfig.Client
    /// User agent of the InnerTube client that minted the URL, sent on media requests so they
    /// stay consistent with the `/player` call. Neither the manifest host nor googlevideo was
    /// observed to enforce it (both serve a mismatched or absent agent), so this is about not
    /// presenting as two different clients rather than a requirement.
    let userAgent: String
    /// True for an HLS multivariant playlist (adaptive), false for a single progressive file.
    let isAdaptive: Bool
    /// Language tag of the video's own audio — `en-US` for a video shot in English — or nil when
    /// there is nothing to choose: every video YouTube hasn't dubbed, and every progressive
    /// stream, whose single track is muxed in.
    ///
    /// Needed because the HLS manifest for a dubbed video does not carry this. YouTube auto-dubs
    /// into a dozen languages, lists the renditions alphabetically by language code with the
    /// original appended *last*, and marks every one of them `DEFAULT=NO` — the API knows which is
    /// the original (`audioTrack.audioIsDefault`) but that fact does not survive into the playlist.
    /// With no default declared and no rendition matching the Apple TV's language, AVFoundation
    /// falls back to the first autoselectable one, which is whichever dub sorts first alphabetically
    /// by language code. See `reference/INNERTUBE.md` and `PlayerView.selectAudioLanguage`.
    ///
    /// `audioIsDefault` marks the original rather than whatever suits the request's `hl`: verified
    /// against four videos with non-English originals (three German, one Spanish), each requested
    /// with `hl=en` and each carrying an English dub, where the flag stayed on the original every
    /// time. Worth re-checking if the app ever sends an `hl` other than `en`.
    let originalAudioLanguage: String?
}

/// Resolves an AVPlayer-ready stream for a videoId.
///
/// Strategy, in order:
///  1. VISIONOS client (+ scraped `visitorData`) → `streamingData.hlsManifestUrl`. This is a
///     full HLS ladder from 144p to 2160p60. AVFoundation picks variants itself and ignores
///     the VP9 ones it can't decode, so playback settles at 1080p60 H.264 — the highest
///     resolution YouTube publishes in a codec Apple TV hardware can decode.
///  2. ANDROID client → muxed progressive itag 18 (360p MP4). Last resort: no ABR, no audio
///     track selection, but it needs no session token and keeps playback working if the
///     VISIONOS client is ever gated behind SABR (server-driven ABR) like ANDROID and IOS
///     already are.
///
/// Deliberately not used: `streamingData.adaptiveFormats`. Above 1080p YouTube only publishes
/// VP9 (WebM) and AV1, neither of which any shipping Apple TV can decode — AVFoundation has no
/// WebM demuxer at all, and AV1 hardware decode starts at A17 Pro while Apple TV 4K tops out
/// at A15. See reference/INNERTUBE.md.
struct StreamService {
    /// The clients to try, in order. A client that resolves a URL is not necessarily one that
    /// plays: `after:` lets the caller walk further down this list when playback itself fails.
    private static let ladder: [AppConfig.Client] = [.visionOS, .android]

    /// Resolves a stream, optionally skipping past a client that already let us down.
    ///
    /// `after` is for the case a URL resolves fine and then won't play — YouTube occasionally
    /// serves an HLS manifest whose audio renditions all 404, which no amount of retrying the
    /// same client fixes. Passing the client that failed resumes the ladder at the next one.
    func resolveStream(
        videoId: String,
        after failedClient: AppConfig.Client? = nil
    ) async throws -> ResolvedStream {
        var firstFailure: Error?

        var remaining = Self.ladder[...]
        if let failedClient, let index = remaining.firstIndex(of: failedClient) {
            remaining = remaining[(index + 1)...]
        }

        for client in remaining {
            do {
                let outcome = try await resolve(videoId: videoId, client: client)
                switch outcome {
                case .stream(let stream):
                    return stream
                case .skip(let reason):
                    #if DEBUG
                    print("[StreamService] \(client.name) skipped: \(reason ?? "nothing usable")")
                    #endif
                    // A gated client is a reason to try the next one, not to report — but if the
                    // whole ladder ends up empty its explanation is the best we have, so keep it
                    // rather than falling back to the generic `.noStream`. Statuses that gate a
                    // client (LOGIN_REQUIRED, ERROR) are also what a genuinely unavailable video
                    // returns from *every* client, e.g. "This video is unavailable" for a deleted
                    // or private one, so this is the path that carries the real message.
                    if firstFailure == nil, let reason, !reason.isEmpty {
                        firstFailure = StreamError.notPlayable(reason)
                    }
                }
            } catch {
                // Cancellation means nobody is waiting for a stream any more: rethrow instead of
                // burning the next client in the ladder on a request that is already abandoned.
                if isCancellation(error) { throw error }
                #if DEBUG
                print("[StreamService] \(client.name) failed: \(error.localizedDescription)")
                #endif
                // Keep the first failure: it comes from the preferred client and so carries the
                // most meaningful reason to show if every client fails.
                if firstFailure == nil { firstFailure = error }
            }
        }

        throw firstFailure ?? StreamError.noStream
    }

    // MARK: - Per-client resolution

    /// What one client in the ladder had to offer.
    private enum ClientOutcome {
        case stream(ResolvedStream)
        /// Nothing usable from this client — try the next. Carries YouTube's human-readable
        /// explanation when there was one, so it can be surfaced if no client succeeds.
        case skip(reason: String?)
    }

    private func resolve(videoId: String, client: AppConfig.Client) async throws -> ClientOutcome {
        var visitorData: String?
        if client.requiresVisitorData {
            visitorData = try await VisitorDataStore.shared.token()
        }

        var json = try await post(videoId: videoId, client: client, visitorData: visitorData)

        // An expired visitorData looks exactly like never having sent one, so retry once with a
        // fresh token before believing the rejection.
        if client.requiresVisitorData, json.string(at: "playabilityStatus/status") == "LOGIN_REQUIRED" {
            await VisitorDataStore.shared.invalidate()
            visitorData = try await VisitorDataStore.shared.token()
            json = try await post(videoId: videoId, client: client, visitorData: visitorData)
        }

        // Playability gate. Only ever surface YouTube's human-readable reason; internal status
        // codes fall through to the generic friendly message instead of being shown to the user.
        let status = json.string(at: "playabilityStatus/status")
        if status != "OK" {
            let reason =
                json.string(at: "playabilityStatus/reason")
                ?? json.string(at: "playabilityStatus/errorScreen/playerErrorMessageRenderer/reason/simpleText")
                ?? ""
            // LOGIN_REQUIRED and ERROR are ambiguous: they are what a gated client returns, and
            // also what an unavailable video returns from every client. Treat them as "try the
            // next client" and pass the reason up, so the ladder can still fall back but the
            // message survives if nothing works.
            if status == "LOGIN_REQUIRED" || status == "ERROR" { return .skip(reason: reason) }
            throw StreamError.notPlayable(reason)
        }

        // 1) HLS multivariant playlist — adaptive, audio included, native quality UI.
        if let hls = json.string(at: "streamingData/hlsManifestUrl"),
            let url = URL(string: hls)
        {
            return .stream(
                ResolvedStream(
                    url: url, client: client, userAgent: client.userAgent, isAdaptive: true,
                    originalAudioLanguage: originalAudioLanguage(in: json)))
        }

        // 2) Progressive (muxed audio+video) formats under streamingData.formats.
        let formats =
            (json.value(at: "streamingData/formats") as? [Any])?
            .compactMap { $0 as? [String: Any] } ?? []

        // Prefer itag 18 (360p MP4) — the one muxed format that reliably carries a plain `url`
        // with no signatureCipher and no `n` throttle param, so it needs no JS deciphering.
        if let url = formats.lazy
            .filter({ intValue($0["itag"]) == 18 })
            .compactMap({ usableURL(from: $0) })
            .first
        {
            return .stream(
                ResolvedStream(
                    url: url, client: client, userAgent: client.userAgent, isAdaptive: false,
                    originalAudioLanguage: nil))
        }

        // Otherwise the first progressive MP4 that yields a usable url — a malformed url on one
        // entry must not stop us from trying later ones.
        if let url = formats.lazy
            .filter({ isProgressiveMP4($0) })
            .compactMap({ usableURL(from: $0) })
            .first
        {
            return .stream(
                ResolvedStream(
                    url: url, client: client, userAgent: client.userAgent, isAdaptive: false,
                    originalAudioLanguage: nil))
        }

        // Playable, but this client returned nothing we can use — typically SABR-only, where
        // every format carries a serverAbrStreamingUrl instead of a plain url. No reason to
        // report: the video is fine, this client just can't serve it.
        return .skip(reason: nil)
    }

    private func post(
        videoId: String,
        client: AppConfig.Client,
        visitorData: String?
    ) async throws -> [String: Any] {
        try await InnerTubeClient.post(
            endpoint: "player",
            client: client,
            params: [
                "videoId": videoId,
                "contentCheckOk": true,
                "racyCheckOk": true,
            ],
            bearer: nil,
            visitorData: visitorData
        )
    }

    // MARK: - Helpers

    /// The language tag of the track YouTube considers this video's own, from
    /// `adaptiveFormats[].audioTrack`.
    ///
    /// `audioTrack` is present only once a video has been dubbed; an undubbed video has no
    /// `audioTrack` on any format and this returns nil, which is correct — there is only one
    /// track and nothing to select. `id` reads `en-US.4`, the tag followed by a track number, and
    /// only the tag is wanted: it is what the HLS rendition's `LANGUAGE` attribute carries.
    ///
    /// `adaptiveFormats` is otherwise unused for playback (see the note on `StreamService`), and
    /// still is — this reads one field off it rather than taking a stream from it.
    private func originalAudioLanguage(in json: [String: Any]) -> String? {
        let formats =
            (json.value(at: "streamingData/adaptiveFormats") as? [Any])?
            .compactMap { $0 as? [String: Any] } ?? []

        for format in formats {
            guard let track = format["audioTrack"] as? [String: Any],
                track["audioIsDefault"] as? Bool == true,
                let id = track["id"] as? String
            else { continue }
            // `split` drops empty subsequences, so `first` is either nil or non-empty.
            return id.split(separator: ".").first.map(String.init)
        }
        return nil
    }

    private func usableURL(from format: [String: Any]) -> URL? {
        guard let s = format["url"] as? String, !s.isEmpty,
            let url = URL(string: s)
        else { return nil }
        return url
    }

    private func isProgressiveMP4(_ format: [String: Any]) -> Bool {
        guard let s = format["url"] as? String, !s.isEmpty else { return false }
        let mime = (format["mimeType"] as? String)?.lowercased() ?? ""
        return mime.hasPrefix("video/mp4")
    }

    /// InnerTube sometimes encodes numeric fields (like itag) as Int, Double, or String.
    private func intValue(_ any: Any?) -> Int? {
        switch any {
        case let i as Int: return i
        case let d as Double: return Int(d)
        case let s as String: return Int(s)
        case let n as NSNumber: return n.intValue
        default: return nil
        }
    }
}
