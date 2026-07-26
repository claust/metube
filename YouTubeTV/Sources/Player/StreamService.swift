import Foundation

/// Errors surfaced while resolving a playable stream URL.
enum StreamError: LocalizedError {
    case notPlayable(String)
    case noStream

    var errorDescription: String? {
        switch self {
        case .notPlayable(let reason):
            return reason.isEmpty
                ? "This video can't be played."
                : "This video can't be played: \(reason)"
        case .noStream:
            return "No playable stream was found for this video."
        }
    }
}

/// A stream ready to hand to AVFoundation, along with the headers its URLs must be fetched with.
struct ResolvedStream {
    let url: URL
    /// Headers for every media request. googlevideo serves the segments regardless, but the
    /// manifest host is picky about matching the client that minted the URL.
    let httpHeaders: [String: String]
    /// True for an HLS multivariant playlist (adaptive), false for a single progressive file.
    let isAdaptive: Bool
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
    func resolveStream(videoId: String) async throws -> ResolvedStream {
        var firstFailure: Error?

        for client in [AppConfig.Client.visionOS, .android] {
            do {
                if let stream = try await resolve(videoId: videoId, client: client) {
                    return stream
                }
            } catch {
                if Task.isCancelled { throw error }
                #if DEBUG
                print("[StreamService] \(client.name) failed: \(error.localizedDescription)")
                #endif
                // Keep the first failure: it comes from the preferred client and so carries the
                // most meaningful reason (e.g. "Private video") to show if every client fails.
                if firstFailure == nil { firstFailure = error }
            }
        }

        throw firstFailure ?? StreamError.noStream
    }

    // MARK: - Per-client resolution

    /// Returns nil when the client answered successfully but had nothing playable to offer,
    /// which means "try the next client". Throws when the video itself is unplayable.
    private func resolve(videoId: String, client: AppConfig.Client) async throws -> ResolvedStream? {
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

        // Playability gate.
        let status = json.string(at: "playabilityStatus/status")
        if status != "OK" {
            // A client-specific rejection (this client is gated, not the video) should fall
            // through to the next client rather than being reported to the user.
            if status == "LOGIN_REQUIRED" || status == "ERROR" { return nil }
            // Only surface a human-readable reason; internal status codes fall through to the
            // generic friendly message instead of being shown to the user.
            let reason = json.string(at: "playabilityStatus/reason")
                ?? json.string(at: "playabilityStatus/errorScreen/playerErrorMessageRenderer/reason/simpleText")
                ?? ""
            throw StreamError.notPlayable(reason)
        }

        let headers = ["User-Agent": client.userAgent]

        // 1) HLS multivariant playlist — adaptive, audio included, native quality UI.
        if let hls = json.string(at: "streamingData/hlsManifestUrl"),
           let url = URL(string: hls) {
            return ResolvedStream(url: url, httpHeaders: headers, isAdaptive: true)
        }

        // 2) Progressive (muxed audio+video) formats under streamingData.formats.
        let formats = (json.value(at: "streamingData/formats") as? [Any])?
            .compactMap { $0 as? [String: Any] } ?? []

        // Prefer itag 18 (360p MP4) — the one muxed format that reliably carries a plain `url`
        // with no signatureCipher and no `n` throttle param, so it needs no JS deciphering.
        if let url = formats.lazy
            .filter({ intValue($0["itag"]) == 18 })
            .compactMap({ usableURL(from: $0) })
            .first {
            return ResolvedStream(url: url, httpHeaders: headers, isAdaptive: false)
        }

        // Otherwise the first progressive MP4 that yields a usable url — a malformed url on one
        // entry must not stop us from trying later ones.
        if let url = formats.lazy
            .filter({ isProgressiveMP4($0) })
            .compactMap({ usableURL(from: $0) })
            .first {
            return ResolvedStream(url: url, httpHeaders: headers, isAdaptive: false)
        }

        // Playable, but this client returned nothing we can use — typically SABR-only, where
        // every format carries a serverAbrStreamingUrl instead of a plain url.
        return nil
    }

    private func post(videoId: String,
                      client: AppConfig.Client,
                      visitorData: String?) async throws -> [String: Any] {
        try await InnerTubeClient.post(
            endpoint: "player",
            client: client,
            params: [
                "videoId": videoId,
                "contentCheckOk": true,
                "racyCheckOk": true
            ],
            bearer: nil,
            visitorData: visitorData
        )
    }

    // MARK: - Helpers

    private func usableURL(from format: [String: Any]) -> URL? {
        guard let s = format["url"] as? String, !s.isEmpty,
              let url = URL(string: s) else { return nil }
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
