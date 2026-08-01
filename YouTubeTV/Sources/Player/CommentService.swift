import Foundation

/// Errors surfaced while fetching comments.
enum CommentError: LocalizedError {
    case commentsUnavailable

    var errorDescription: String? {
        switch self {
        case .commentsUnavailable:
            return "Comments aren't available for this video."
        }
    }
}

/// A single comment — top-level or reply — ready for display.
struct CommentItem: Identifiable, Hashable {
    /// InnerTube's commentId. Replies embed their parent's id ("parent.reply"), so ids stay
    /// unique across a mixed list.
    let id: String
    /// The author's handle ("@name"), which is how InnerTube labels comment authors.
    let author: String
    let avatarURL: URL?
    /// The comment's plain text. Emoji arrive literally; formatting arrives as markdown-ish
    /// markup, shown verbatim — a prototype-level compromise.
    let text: String
    /// InnerTube's relative timestamp ("1 year ago"), shown verbatim.
    let publishedTime: String
    /// Already-abbreviated like count ("278K"), shown verbatim. "0" when the comment has none.
    let likeCount: String
    /// Already-abbreviated reply count. Empty when the comment has no replies — InnerTube omits
    /// the field rather than sending "0".
    let replyCount: String
    /// Token that fetches this comment's replies. `nil` when it has none (replies themselves
    /// never carry one — YouTube reply threads are flat).
    let repliesToken: String?

    var hasReplies: Bool { repliesToken != nil }
}

/// One page of comments plus the token for the page after it, if any.
struct CommentPage {
    let comments: [CommentItem]
    /// `nil` once the list is exhausted.
    let continuation: String?
}

/// Fetches a video's comments and their replies via InnerTube `/next` (WEB client,
/// unauthenticated). See reference/INNERTUBE.md ("COMMENTS") for the verified response shapes.
///
/// Two-step flow: `/next {"videoId"}` only says *where* the comments are (a continuation token
/// on the watch page's comment section); `/next {"continuation"}` returns the actual comments.
/// Comment data lives in `frameworkUpdates` as `commentEntityPayload` entities keyed by
/// commentId, while ordering and reply tokens come from the renderer list — so a page is parsed
/// by joining the two on commentId.
struct CommentService {
    /// The first page of top-level comments, sorted by YouTube's default "Top comments" order.
    func topLevelComments(videoId: String) async throws -> CommentPage {
        let json = try await InnerTubeClient.post(
            endpoint: "next",
            client: .web,
            params: ["videoId": videoId])
        // The watch page carries the comment section twice (inline and as an engagement
        // panel), both marked with the same sectionIdentifier; their tokens differ but both
        // resolve to the same comment list, so any match works.
        let section = findAllRenderers(named: "itemSectionRenderer", in: json)
            .first { $0["sectionIdentifier"] as? String == "comment-item-section" }
        guard let section, let token = firstContinuationToken(in: section) else {
            // No comment section on the watch page — comments are off for this video.
            throw CommentError.commentsUnavailable
        }
        return try await page(continuation: token)
    }

    /// Any comments page: the top-level list, its later pages, a comment's replies, and
    /// "show more replies" pages — the response shapes differ, but all are parsed here.
    func page(continuation: String) async throws -> CommentPage {
        let json = try await InnerTubeClient.post(
            endpoint: "next",
            client: .web,
            params: ["continuation": continuation])

        // The comments themselves: entity payloads keyed by commentId.
        var payloads: [String: [String: Any]] = [:]
        for payload in findAllRenderers(named: "commentEntityPayload", in: json) {
            if let id = payload.string(at: "properties/commentId") {
                payloads[id] = payload
            }
        }

        // Ordering and reply tokens. A top-level page wraps each comment in a
        // commentThreadRenderer (which also holds the replies token); a replies page has no
        // threads — its items are bare commentViewModels in reply order.
        var comments: [CommentItem] = []
        let threads = findAllRenderers(named: "commentThreadRenderer", in: json)
        if threads.isEmpty {
            for viewModel in findAllRenderers(named: "commentViewModel", in: json) {
                guard let id = viewModel["commentId"] as? String, let payload = payloads[id] else { continue }
                comments.append(item(from: payload, id: id, repliesToken: nil))
            }
        } else {
            for thread in threads {
                guard let id = commentId(in: thread), let payload = payloads[id] else { continue }
                // The one continuationCommand under `replies` is the replies token — the
                // view/hide-replies buttons around it carry no token of their own.
                let repliesToken = (thread["replies"] as? [String: Any])
                    .flatMap(firstContinuationToken(in:))
                comments.append(item(from: payload, id: id, repliesToken: repliesToken))
            }
        }

        return CommentPage(comments: comments, continuation: nextPageToken(in: json))
    }

    // MARK: - Parsing helpers

    private func item(from payload: [String: Any], id: String, repliesToken: String?) -> CommentItem {
        let likeCount = payload.string(at: "toolbar/likeCountNotliked") ?? ""
        return CommentItem(
            id: id,
            author: payload.string(at: "author/displayName") ?? "",
            avatarURL: payload.string(at: "author/avatarThumbnailUrl").flatMap(URL.init(string:)),
            text: payload.string(at: "properties/content/content") ?? "",
            publishedTime: payload.string(at: "properties/publishedTime") ?? "",
            likeCount: likeCount.isEmpty ? "0" : likeCount,
            replyCount: payload.string(at: "toolbar/replyCount") ?? "",
            repliesToken: repliesToken)
    }

    /// A thread's commentId lives on the commentViewModel nested inside its wrapper of the
    /// same name; recursing for the innermost one with an id reads through both layers.
    private func commentId(in thread: [String: Any]) -> String? {
        findAllRenderers(named: "commentViewModel", in: thread)
            .compactMap { $0["commentId"] as? String }
            .first
    }

    private func firstContinuationToken(in renderer: [String: Any]) -> String? {
        findAllRenderers(named: "continuationCommand", in: renderer)
            .compactMap { $0["token"] as? String }
            .first
    }

    /// The token for the page after this one: the trailing continuationItemRenderer of the
    /// response's continuation-items list. Only the *last* item is considered — the renderers
    /// nested inside each thread are reply tokens, not paging. Covers both paging shapes: a
    /// plain continuation item (top-level pages) and a "Show more replies" button (replies).
    private func nextPageToken(in json: [String: Any]) -> String? {
        guard let endpoints = json["onResponseReceivedEndpoints"] as? [Any] else { return nil }
        for endpoint in endpoints {
            guard let endpoint = endpoint as? [String: Any] else { continue }
            // reloadContinuationItemsCommand on the first page, appendContinuationItemsAction
            // on later ones — same shape under either key.
            for command in endpoint.values {
                guard let command = command as? [String: Any],
                    let items = command["continuationItems"] as? [Any],
                    let last = items.last as? [String: Any],
                    let renderer = last["continuationItemRenderer"] as? [String: Any],
                    let token = firstContinuationToken(in: renderer)
                else { continue }
                return token
            }
        }
        return nil
    }
}
