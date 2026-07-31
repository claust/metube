import SwiftUI

/// The comments panel the player's "Comments" button brings up: a partly transparent column
/// pinned to the right edge of the screen, over video that keeps playing.
///
/// Two levels deep, mirroring YouTube's flat reply threads: the top-level list, and one
/// comment's replies with that comment pinned above them. Select on a comment with replies
/// goes down a level; Menu comes back up, and closes the overlay from the top level (the
/// hosting controller supplies that dismissal — see PlayerView).
struct CommentsOverlayView: View {
    let videoId: String
    var onClose: () -> Void

    /// The comment whose replies are on screen; `nil` while the top-level list is.
    @State private var parent: CommentItem?
    @State private var topLevel = CommentList()
    @State private var replies = CommentList()

    private static let panelWidth: CGFloat = 640

    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            panel
                .frame(width: Self.panelWidth)
                .frame(maxHeight: .infinity)
                // Dark enough to read white text over any video frame, light enough that the
                // picture stays visible through it.
                .background(.black.opacity(0.55))
                .background(.ultraThinMaterial)
        }
        .ignoresSafeArea()
        .onExitCommand {
            if parent != nil {
                parent = nil
                // Cleared eagerly rather than left for `.task` to overwrite, so opening the
                // next comment's replies can't briefly show this comment's list.
                replies = CommentList()
            } else {
                onClose()
            }
        }
        .task(id: parent?.id) {
            // The flag is flipped on the state itself before the await — `loaded` works on a
            // copy, so nothing else would show the spinner while the fetch is in flight.
            // A cancelled run's result is dropped: navigating away restarts this task, and a
            // stale fetch finishing late must not overwrite the list the new run owns.
            if let parent {
                replies.isLoading = true
                let result = await loaded(CommentList(), from: parent.repliesToken)
                if !Task.isCancelled { replies = result }
            } else if topLevel.comments.isEmpty {
                topLevel.isLoading = true
                let result = await loaded(CommentList(), fromVideo: videoId)
                if !Task.isCancelled { topLevel = result }
            }
        }
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            list
        }
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(parent == nil ? "Comments" : "Replies")
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(.white)
            Text(parent == nil ? "Press Menu to close" : "Press Menu to go back")
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.top, 60)
        .padding(.horizontal, 40)
        .padding(.bottom, 24)
    }

    @ViewBuilder
    private var list: some View {
        let current = parent == nil ? topLevel : replies
        if current.comments.isEmpty && current.isLoading {
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if current.comments.isEmpty && current.loadFailed {
            failureNotice
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let parent {
                        // The comment being replied to, pinned above its replies for context.
                        CommentRow(comment: parent, showsReplyCount: false, action: nil)
                        Divider().background(.white.opacity(0.3))
                    }
                    ForEach(current.comments) { comment in
                        CommentRow(
                            comment: comment,
                            showsReplyCount: true,
                            // Only a top-level comment with replies navigates; a reply row is
                            // focusable (that's what scrolls the list) but Select does nothing.
                            action: comment.hasReplies && parent == nil
                                ? { parent = comment } : nil)
                    }
                    if current.continuation != nil {
                        LoadMoreRow(
                            title: parent == nil ? "More comments" : "More replies",
                            isLoading: current.isLoading,
                            action: loadMore)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 60)
            }
        }
    }

    private var failureNotice: some View {
        VStack(spacing: 20) {
            Text("Comments couldn't be loaded.")
                .font(.system(size: 26))
                .foregroundStyle(.white)
            Button("Close", action: onClose)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loading

    /// One list with one more page in it. Every failure is swallowed into `loadFailed`: with a
    /// video already playing underneath, a comments hiccup is worth a notice, never an alert.
    private func loaded(_ list: CommentList, from token: String?) async -> CommentList {
        guard let token else { return list }
        var list = list
        list.isLoading = true
        do {
            let page = try await CommentService().page(continuation: token)
            list.comments += page.comments
            list.continuation = page.continuation
            list.loadFailed = false
        } catch {
            list.loadFailed = true
        }
        list.isLoading = false
        return list
    }

    private func loaded(_ list: CommentList, fromVideo videoId: String) async -> CommentList {
        var list = list
        list.isLoading = true
        do {
            let page = try await CommentService().topLevelComments(videoId: videoId)
            list.comments += page.comments
            list.continuation = page.continuation
            list.loadFailed = false
        } catch {
            list.loadFailed = true
        }
        list.isLoading = false
        return list
    }

    private func loadMore() {
        // The guard and the flag both happen before anything suspends, so a second Select on
        // the row while a page is in flight can't start a duplicate fetch.
        if parent == nil {
            guard !topLevel.isLoading, topLevel.continuation != nil else { return }
            topLevel.isLoading = true
            Task { topLevel = await loaded(topLevel, from: topLevel.continuation) }
        } else {
            guard !replies.isLoading, replies.continuation != nil else { return }
            replies.isLoading = true
            Task { replies = await loaded(replies, from: replies.continuation) }
        }
    }
}

/// Accumulated pages of one comment list plus its load state.
private struct CommentList {
    var comments: [CommentItem] = []
    /// Token for the next page; `nil` once exhausted.
    var continuation: String?
    var isLoading = false
    var loadFailed = false
}

// MARK: - Row

/// One comment: avatar, author and age, the text, and a likes/replies footer.
private struct CommentRow: View {
    let comment: CommentItem
    /// Off for the pinned parent above a replies list — its reply count is the list below it.
    let showsReplyCount: Bool
    /// What Select does. `nil` still renders a focusable button (focus is how the list
    /// scrolls on tvOS) that just does nothing.
    let action: (() -> Void)?

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 10) {
                byline
                Text(comment.text)
                    .font(.system(size: 25))
                    .foregroundStyle(.white)
                    .lineLimit(isFocused ? 40 : 6)
                    .fixedSize(horizontal: false, vertical: true)
                counts
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(isFocused ? 0.22 : 0.07)))
        }
        .buttonStyle(CommentRowButtonStyle())
        .focused($isFocused)
    }

    private func select() {
        action?()
    }

    private var byline: some View {
        HStack(spacing: 12) {
            avatar
            Text(comment.author)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
            Text(comment.publishedTime)
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.55))
        }
        .lineLimit(1)
    }

    private var avatar: some View {
        AsyncImage(url: comment.avatarURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color.white.opacity(0.15)
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
    }

    private var counts: some View {
        HStack(spacing: 28) {
            Label(comment.likeCount, systemImage: "hand.thumbsup")
            if showsReplyCount && comment.hasReplies {
                Label(
                    comment.replyCount.isEmpty ? "Replies" : "\(comment.replyCount) replies",
                    systemImage: "text.bubble")
                // Only a row that actually navigates advertises it.
                if action != nil {
                    Image(systemName: "chevron.right")
                }
            }
        }
        .font(.system(size: 20, weight: .medium))
        .foregroundStyle(.white.opacity(0.7))
    }
}

/// The paging control at the bottom of either list.
private struct LoadMoreRow: View {
    let title: String
    let isLoading: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack {
                Spacer()
                if isLoading {
                    ProgressView().tint(.white)
                } else {
                    Text(title)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white)
                }
                Spacer()
            }
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(isFocused ? 0.22 : 0.07)))
        }
        .buttonStyle(CommentRowButtonStyle())
        .focused($isFocused)
    }
}

/// Keeps the label exactly as drawn — the row draws its own focus treatment, and the default
/// tvOS button chrome (white platter, lift) would fight the translucent panel.
private struct CommentRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
