import Foundation

/// Who a set of tokens belongs to: enough to label an avatar in the profile bar.
struct AccountInfo: Hashable {
    /// Stable identity for the account — Google's obfuscated Gaia id where the response
    /// carries one, which survives a rename of both the account and its channel.
    let key: String
    let name: String
    let avatarURL: URL?
}

enum AccountError: LocalizedError {
    case notFound

    var errorDescription: String? {
        switch self {
        case .notFound: return "YouTube didn't say which account these credentials belong to"
        }
    }
}

/// Reads the signed-in account's name and avatar from InnerTube's account list.
///
/// This is the only call in the app that answers "who is this?", which is what turns a set of
/// tokens into a profile the user can recognise on screen. `account/accounts_list` takes no
/// parameters — it describes whoever the Bearer token belongs to. (The `account/account_menu`
/// endpoint the web client uses for this answers HTTP 400 on TVHTML5; verified 2026-07-27.)
struct AccountService {
    func loadAccount(accessToken: String) async throws -> AccountInfo {
        let json = try await InnerTubeClient.post(
            endpoint: "account/accounts_list",
            client: .tv,
            params: [:],
            bearer: accessToken
        )
        guard let info = Self.parse(json) else { throw AccountError.notFound }
        return info
    }

    // MARK: - Parsing

    /// Picks the account these credentials are signed in as. A device-flow token is bound to one
    /// account so the list is normally a single entry, but it is a *list* — `isSelected` is what
    /// names the right one, and only its absence falls back to the first.
    static func parse(_ json: [String: Any]) -> AccountInfo? {
        let items = findAllRenderers(named: "accountItem", in: json)
        guard let item = items.first(where: { $0["isSelected"] as? Bool == true }) ?? items.first else {
            return nil
        }

        let name = innerTubeText(item["accountName"]) ?? ""
        let candidates = [
            gaiaID(in: item),
            innerTubeText(item["channelHandle"]),
            innerTubeText(item["accountByline"]),
            name,
        ]
        guard let key = candidates.compactMap({ $0 }).first(where: { !$0.isEmpty }) else { return nil }

        return AccountInfo(
            key: key,
            name: name.isEmpty ? key : name,
            avatarURL: largestThumbnail(in: item["accountPhoto"])
        )
    }

    /// Google's own id for the account, tucked into the endpoint that would switch to it.
    private static func gaiaID(in item: [String: Any]) -> String? {
        findAllRenderers(named: "accountStateToken", in: item)
            .compactMap { $0["obfuscatedGaiaId"] as? String }
            .first { !$0.isEmpty }
    }

    /// The biggest of the avatar sizes YouTube offers — the bar draws them small, but a tvOS
    /// screen is large enough that the smaller variants are visibly soft.
    private static func largestThumbnail(in object: Any?) -> URL? {
        guard let dict = object as? [String: Any],
            let thumbnails = dict["thumbnails"] as? [[String: Any]]
        else { return nil }
        let best = thumbnails.max { ($0["width"] as? Int ?? 0) < ($1["width"] as? Int ?? 0) }
        guard var url = best?["url"] as? String, !url.isEmpty else { return nil }
        // Avatar URLs occasionally come back protocol-relative.
        if url.hasPrefix("//") { url = "https:" + url }
        return URL(string: url)
    }
}
