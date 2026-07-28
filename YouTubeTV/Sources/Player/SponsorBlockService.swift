import CryptoKit
import Foundation

/// One community-submitted stretch of a video that isn't the video: a read-out sponsor spot,
/// a "like and subscribe" plug, an intro animation.
struct SponsorSegment: Identifiable, Hashable {
    let id: String  // SponsorBlock's UUID for the submission
    let category: SponsorCategory
    let start: TimeInterval
    let end: TimeInterval

    var duration: TimeInterval { end - start }

    func contains(_ time: TimeInterval) -> Bool {
        time >= start && time < end
    }
}

/// The kinds of interruption SponsorBlock distinguishes. Raw values are the API's own
/// identifiers and are sent verbatim in the `categories` query parameter.
enum SponsorCategory: String, CaseIterable, Codable {
    case sponsor
    case selfPromo = "selfpromo"
    case interaction
    case intro
    case outro
    case preview
    case filler
    case musicOffTopic = "music_offtopic"

    /// Shown in the "skipped" toast.
    var displayName: String {
        switch self {
        case .sponsor: return "Sponsor"
        case .selfPromo: return "Self-promotion"
        case .interaction: return "Subscribe reminder"
        case .intro: return "Intro"
        case .outro: return "Outro"
        case .preview: return "Recap"
        case .filler: return "Filler"
        case .musicOffTopic: return "Non-music section"
        }
    }

    /// What gets skipped unless configured otherwise. The four that are unambiguously *not*
    /// the video the user chose to watch. `intro`/`outro`/`preview`/`filler` are editorial
    /// parts of the video itself — plenty of people want them, so they're opt-in.
    static let defaultSkipped: Set<SponsorCategory> = [
        .sponsor, .selfPromo, .interaction, .musicOffTopic,
    ]
}

/// Fetches SponsorBlock segments for a video.
///
/// SponsorBlock (https://sponsor.ajay.app, AGPL, ~100M+ submitted segments) is a crowd-sourced
/// database of timestamped in-video interruptions. The browser extension is the well-known
/// client; the API behind it is public, unauthenticated and free, which is all this needs.
///
/// Privacy: the videoId is never sent. The endpoint takes the **first four hex characters of
/// its SHA-256** and returns every video whose hash starts with those characters — a few dozen
/// videos — and the match is made locally. So the server learns that someone is watching one of
/// ~1/65536 of YouTube, not which video. This is SponsorBlock's recommended mode and costs one
/// slightly larger response.
enum SponsorBlockService {

    /// Segments for `videoId` in the given categories, sorted by start time and merged where
    /// they overlap. Returns an empty array when nobody has submitted anything for the video.
    static func fetchSegments(
        videoId: String,
        categories: Set<SponsorCategory> = SponsorCategory.defaultSkipped
    ) async throws -> [SponsorSegment] {
        guard !categories.isEmpty else { return [] }

        let hash = sha256Hex(videoId)
        let prefix = String(hash.prefix(4))

        var components = URLComponents(
            string: "https://sponsor.ajay.app/api/skipSegments/\(prefix)")!
        components.queryItems = [
            // Both are JSON arrays in the query string, which is what the API expects.
            URLQueryItem(name: "categories", value: jsonArray(categories.map(\.rawValue).sorted())),
            // "skip" only: SponsorBlock also has "mute" (lower the volume, keep the picture)
            // and "poi"/"chapter" entries, none of which this prototype acts on — asking for
            // them would only mean filtering them out again.
            URLQueryItem(name: "actionTypes", value: jsonArray(["skip"])),
        ]

        var request = URLRequest(url: components.url!)
        // SponsorBlock asks clients to identify themselves so abusive traffic can be told apart
        // from ordinary use.
        request.setValue("metube-tvOS/0.1", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8

        let (data, response) = try await URLSession.shared.data(for: request)
        // 404 is the ordinary "no segments for any video in this hash prefix" answer, not a
        // failure — and neither is anything else here: this is an optional enhancement, so a
        // SponsorBlock outage must never keep a video from playing.
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }

        let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []

        // The response covers every video sharing the hash prefix; only ours is interesting.
        // Compare on the full hash as well, since videoID alone is what the server echoes back.
        let mine = entries.first { entry in
            (entry["videoID"] as? String) == videoId
                || (entry["hash"] as? String)?.lowercased() == hash
        }
        guard let raw = mine?["segments"] as? [[String: Any]] else { return [] }

        return merge(raw.compactMap(parse(segment:)))
    }

    // MARK: - Parsing

    private static func parse(segment: [String: Any]) -> SponsorSegment? {
        guard let uuid = segment["UUID"] as? String,
            let categoryName = segment["category"] as? String,
            let category = SponsorCategory(rawValue: categoryName),
            let bounds = segment["segment"] as? [Double], bounds.count == 2
        else { return nil }

        // Negative votes mean the community has disowned the submission — a segment sitting at
        // -2 is usually a wrong or malicious timestamp, and acting on it cuts real content.
        if let votes = segment["votes"] as? Int, votes < 0 { return nil }

        let (start, end) = (max(0, bounds[0]), bounds[1])
        // Under a second is not worth a seek: the seek itself costs about as much as the
        // segment, and on an HLS stream it can be more disruptive than the ad read.
        guard end - start >= 1 else { return nil }

        return SponsorSegment(id: uuid, category: category, start: start, end: end)
    }

    /// Sorts by start time and folds overlapping or touching segments into one, so two adjacent
    /// sponsor reads become a single seek instead of a seek that lands inside the next segment
    /// and immediately seeks again.
    private static func merge(_ segments: [SponsorSegment]) -> [SponsorSegment] {
        let sorted = segments.sorted { $0.start < $1.start }
        var merged: [SponsorSegment] = []
        for segment in sorted {
            guard let last = merged.last, segment.start <= last.end + 0.5 else {
                merged.append(segment)
                continue
            }
            guard segment.end > last.end else { continue }  // fully contained
            // Keep the earlier segment's identity: it's the one whose start the user reaches,
            // so it's the category worth naming in the toast.
            merged[merged.count - 1] = SponsorSegment(
                id: last.id, category: last.category, start: last.start, end: segment.end)
        }
        return merged
    }

    // MARK: - Helpers

    private static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func jsonArray(_ values: [String]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: values)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}
