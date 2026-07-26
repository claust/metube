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

/// Resolves a direct, AVPlayer-ready stream URL for a videoId using the
/// InnerTube ANDROID client (unauthenticated). Strategy: prefer the muxed
/// progressive itag-18 (360p MP4) format, which carries a plain `url` with no
/// signatureCipher / `n` throttle param. Falls back to any progressive MP4
/// format that already has a plain `url`.
struct StreamService {
    func resolveStreamURL(videoId: String) async throws -> URL {
        let json = try await InnerTubeClient.post(
            endpoint: "player",
            client: .android,
            params: [
                "videoId": videoId,
                "contentCheckOk": true,
                "racyCheckOk": true,
            ],
            bearer: nil
        )

        // Playability gate.
        let status = json.string(at: "playabilityStatus/status")
        if status != "OK" {
            // Only surface a human-readable reason; internal status codes (e.g. LOGIN_REQUIRED)
            // fall through to the generic friendly message instead of being shown to the user.
            let reason =
                json.string(at: "playabilityStatus/reason")
                ?? json.string(at: "playabilityStatus/errorScreen/playerErrorMessageRenderer/reason/simpleText")
                ?? ""
            throw StreamError.notPlayable(reason)
        }

        // Progressive (muxed audio+video) formats live under streamingData.formats.
        let formats =
            (json.value(at: "streamingData/formats") as? [Any])?
            .compactMap { $0 as? [String: Any] } ?? []

        // 1) Prefer itag 18 with a usable url (try every itag-18 entry, not just the first).
        if let url = formats.lazy
            .filter({ intValue($0["itag"]) == 18 })
            .compactMap({ usableURL(from: $0) })
            .first
        {
            return url
        }

        // 2) Fall back to the first progressive MP4 that yields a usable url — a malformed url on
        //    one entry must not stop us from trying later ones.
        if let url = formats.lazy
            .filter({ isProgressiveMP4($0) })
            .compactMap({ usableURL(from: $0) })
            .first
        {
            return url
        }

        throw StreamError.noStream
    }

    // MARK: - Helpers

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
