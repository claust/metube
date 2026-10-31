import Foundation

/// Where a card's "Not interested" and "Don't recommend channel" come from.
///
/// Both are the InnerTube `feedback` call, which takes an opaque token YouTube mints per video
/// and per action — it can't be built from the video id, so a card can only offer them when
/// the cell said how to get one. Cells say it in one of two ways (verified 2026-10-31):
///
/// * Home's tiles carry no menu, only the long-press command that fetches one: a
///   `showEngagementPanelEndpoint` tagged `PAcontext_menu`, whose params go to `get_panel`.
/// * Older row pages carry the menu inline, as a `showMenuCommand` holding a `menuRenderer`.
enum VideoFeedback: Hashable {
    case tokens(FeedbackTokens)
    case panel(params: String)

    /// The engagement panel the TV client opens on a long press — the one holding the menu.
    static let menuPanelID = "PAcontext_menu"

    /// What `cell` offers, or `nil` when it carries neither shape (Subscriptions and History
    /// tiles, whose menus have nothing to dismiss).
    init?(in cell: [String: Any]) {
        for panel in findAllRenderers(named: "showEngagementPanelEndpoint", in: cell)
        where panel.string(at: "identifier/tag") == Self.menuPanelID {
            if let params = panel.string(at: "globalConfiguration/params") {
                self = .panel(params: params)
                return
            }
        }
        let tokens = FeedbackTokens(menu: findAllRenderers(named: "menuRenderer", in: cell))
        guard !tokens.isEmpty else { return nil }
        self = .tokens(tokens)
    }
}

/// The two feedback tokens a card's menu can hold. Either may be missing — a channel's own
/// upload, for one, has nothing to not-recommend on its channel page.
struct FeedbackTokens: Hashable {
    var notInterested: String?
    var dontRecommendChannel: String?

    var isEmpty: Bool { notInterested == nil && dontRecommendChannel == nil }

    /// Picks the tokens out of a menu in either shape: the panel's `listItemViewModel`s, titled
    /// by `title.content`, or an inline menu's `menuServiceItemRenderer`s, titled by `text`.
    ///
    /// Matched by title, which is safe because every request pins `hl` to English. The token is
    /// the first `feedbackToken` under the item: "Don't recommend channel" nests its own behind a
    /// confirmation popup, and that popup's "Confirm" is the only feedback endpoint inside it.
    init(menu: Any) {
        var notInterested: String?
        var dontRecommendChannel: String?
        func walk(_ obj: Any) {
            if let dict = obj as? [String: Any] {
                for (key, value) in dict {
                    guard let item = value as? [String: Any] else { continue }
                    switch Self.title(ofMenuItem: item, key: key) {
                    case "Not interested": notInterested = notInterested ?? Self.firstToken(in: item)
                    case "Don't recommend channel":
                        dontRecommendChannel = dontRecommendChannel ?? Self.firstToken(in: item)
                    default: break
                    }
                }
                for value in dict.values { walk(value) }
            } else if let array = obj as? [Any] {
                for value in array { walk(value) }
            }
        }
        walk(menu)
        self.notInterested = notInterested
        self.dontRecommendChannel = dontRecommendChannel
    }

    /// A menu item's label, or `nil` when `key` isn't one of the two menu item renderers.
    private static func title(ofMenuItem item: [String: Any], key: String) -> String? {
        switch key {
        case "listItemViewModel": return item.string(at: "title/content")
        case "menuServiceItemRenderer", "menuNavigationItemRenderer": return innerTubeText(item["text"])
        default: return nil
        }
    }

    private static func firstToken(in item: [String: Any]) -> String? {
        findAllRenderers(named: "feedbackEndpoint", in: item)
            .lazy.compactMap { $0["feedbackToken"] as? String }.first
    }
}

/// Telling YouTube to show less of something: fetching a card's menu when the cell didn't carry
/// it, and sending the feedback. Same TVHTML5 client and Bearer token as the feeds — the tokens
/// are tied to the account they were served to.
struct FeedbackService {

    /// The tokens behind `feedback`, fetching the long-press menu first when that's where they are.
    func tokens(for feedback: VideoFeedback, accessToken: String) async throws -> FeedbackTokens {
        switch feedback {
        case .tokens(let tokens):
            return tokens
        case .panel(let params):
            // Only this pairing answers: params alone, or the endpoint passed through whole as
            // the command has it, both get a 400 (verified 2026-10-31).
            let json = try await InnerTubeClient.post(
                endpoint: "get_panel",
                client: .tv,
                params: ["panelId": VideoFeedback.menuPanelID, "params": params],
                bearer: accessToken
            )
            return FeedbackTokens(menu: json)
        }
    }

    /// Sends one feedback token. Throws when YouTube says it didn't act on it — the response
    /// reports each token's `isProcessed` — as well as on anything but a 2xx.
    func send(_ token: String, accessToken: String) async throws {
        let json = try await InnerTubeClient.post(
            endpoint: "feedback",
            client: .tv,
            params: ["feedbackTokens": [token]],
            bearer: accessToken
        )
        let responses = json["feedbackResponses"] as? [[String: Any]] ?? []

        #if DEBUG
        print("[FeedbackService] feedback: \(responses.map { $0["isProcessed"] ?? "?" })")
        #endif

        if responses.contains(where: { ($0["isProcessed"] as? Bool) == false }) {
            throw FeedbackError.notProcessed
        }
    }
}

enum FeedbackError: LocalizedError {
    case notProcessed
    var errorDescription: String? { "YouTube didn't accept the feedback" }
}
