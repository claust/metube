import Foundation

/// A video's description as the uploader wrote it, plus the little header YouTube shows above it.
struct VideoDescription {
    let title: String
    let channel: String
    /// "1,832,308,056 views", shown verbatim.
    let viewCount: String
    /// "17 years ago", shown verbatim.
    let publishedTime: String
    /// The description's plain text, newlines and emoji intact.
    let text: String
    /// The tappable stretches of `text`, in order.
    let links: [DescriptionLink]

    /// Only the links that go somewhere off YouTube — what a viewer would want on their phone.
    var webLinks: [DescriptionLink] {
        links.filter { if case .web = $0.kind { return true } else { return false } }
    }
}

/// One stretch of a description that YouTube makes tappable.
struct DescriptionLink: Identifiable, Hashable {
    enum Kind: Hashable {
        /// An outside link, already unwrapped from YouTube's `/redirect` bounce.
        case web(URL)
        /// A chapter or "skip to" timestamp in this same video.
        case timestamp(seconds: Int)
        /// A hashtag, channel mention or anything else that stays inside YouTube.
        case youtube
    }

    /// UTF-16 range into `VideoDescription.text` — InnerTube counts in UTF-16 units, which is
    /// what `NSString` does, so the offsets apply as they come.
    let range: NSRange
    let display: String
    let kind: Kind

    var id: Int { range.location }
}

/// Reads a video's description out of the watch page — `CommentService.watchPage(videoId:)`,
/// the same response that locates the comment section. The description lives in
/// `videoSecondaryInfoRenderer.attributedDescription`: `content` is the text, and `commandRuns`
/// mark the links by UTF-16 offset.
struct DescriptionService {
    func description(inWatchPage json: [String: Any]) -> VideoDescription {
        let primary = findAllRenderers(named: "videoPrimaryInfoRenderer", in: json).first ?? [:]
        let secondary = findAllRenderers(named: "videoSecondaryInfoRenderer", in: json).first ?? [:]
        let owner = findAllRenderers(named: "videoOwnerRenderer", in: secondary).first ?? [:]
        let attributed = secondary["attributedDescription"] as? [String: Any] ?? [:]
        let text = attributed["content"] as? String ?? ""
        let runs = attributed["commandRuns"] as? [[String: Any]] ?? []

        return VideoDescription(
            title: innerTubeText(primary["title"]) ?? "",
            channel: innerTubeText(owner["title"]) ?? "",
            viewCount: primary.string(at: "viewCount/videoViewCountRenderer/viewCount/simpleText")
                ?? "",
            publishedTime: innerTubeText(primary["relativeDateText"]) ?? "",
            text: text,
            links: runs.compactMap { link(from: $0, in: text as NSString) })
    }

    private func link(from run: [String: Any], in text: NSString) -> DescriptionLink? {
        guard let start = run["startIndex"] as? Int, let length = run["length"] as? Int,
            start >= 0, length > 0, start + length <= text.length
        else { return nil }
        let range = NSRange(location: start, length: length)
        let display = text.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        let command = run.value(at: "onTap/innertubeCommand") as? [String: Any] ?? [:]

        let kind: DescriptionLink.Kind
        if let seconds = command.value(at: "watchEndpoint/startTimeSeconds") as? Int {
            kind = .timestamp(seconds: seconds)
        } else if let raw = command.string(at: "urlEndpoint/url"), let url = unwrapped(raw) {
            kind = .web(url)
        } else {
            kind = .youtube
        }
        return DescriptionLink(range: range, display: display, kind: kind)
    }

    private static let youTubeHosts: Set = ["www.youtube.com", "youtube.com", "m.youtube.com"]

    /// YouTube routes outside links through `youtube.com/redirect?q=<target>`; the target is
    /// what belongs on a phone, not a bounce that expires with its token.
    private func unwrapped(_ raw: String) -> URL? {
        guard let components = URLComponents(string: raw) else { return nil }
        // YouTube's own bounce only: an uploader's link to some other site's `/redirect` is
        // exactly where it points. Relative counts as YouTube's, since that is what a host-less
        // URL in a YouTube response is.
        let isYouTube = components.host.map { Self.youTubeHosts.contains($0.lowercased()) } ?? true
        if isYouTube, components.path == "/redirect",
            let target = components.queryItems?.first(where: { $0.name == "q" })?.value
        {
            return URL(string: target)
        }
        return components.url
    }
}
