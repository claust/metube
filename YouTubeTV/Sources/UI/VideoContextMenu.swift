import SwiftUI

extension View {
    /// The menu a long press on a card puts up: go to the uploader's channel, subscribe or
    /// unsubscribe depending on where the account stands with it, and — where YouTube offers
    /// them for the card — "Not interested" and "Don't recommend channel".
    ///
    /// Attached once per screen and driven by the card the user pressed, rather than one menu
    /// per card: a feed holds dozens of cards, and only one menu is ever open.
    ///
    /// A `confirmationDialog` rather than a `contextMenu`, matching the profile bar's menu — on
    /// a d-pad these read as one full-screen list of choices, with Menu backing out of them.
    ///
    /// `onDismiss` is told when the user asks to see less, so the screen can take the card (or,
    /// for a channel, all of its cards) away; screens with nothing to take away leave it out.
    func videoMenu(
        for item: Binding<VideoItem?>,
        onOpenChannel: @escaping (VideoItem) -> Void,
        onDismiss: @escaping (VideoItem, VideoDismissal) -> Void = { _, _ in }
    ) -> some View {
        modifier(VideoMenu(item: item, onOpenChannel: onOpenChannel, onDismiss: onDismiss))
    }
}

/// What the user asked to see less of from a card's menu.
enum VideoDismissal {
    case video
    case channel
}

private struct VideoMenu: ViewModifier {
    @Binding var item: VideoItem?
    let onOpenChannel: (VideoItem) -> Void
    let onDismiss: (VideoItem, VideoDismissal) -> Void

    @EnvironmentObject private var authStore: AuthStore
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @EnvironmentObject private var videoChannels: VideoChannelStore

    /// The card the dialog is showing: `item` with its channel filled in, set once the lookup
    /// has had its chance — see `waitForChannel(of:)`.
    @State private var shown: VideoItem?

    /// The "see less" tokens for `shown`, set just before it — the menu has to be complete the
    /// moment it appears, for the same reason as the channel. `nil` when the card offers none,
    /// or they couldn't be fetched in time.
    @State private var feedbackTokens: FeedbackTokens?

    /// The longest the menu holds back for a channel lookup still under way.
    private static let lookupPatience = Duration.seconds(2)

    func body(content: Content) -> some View {
        content
            .task(id: item?.id) {
                guard let item else { return }
                // Both waits run at once: Home's menu is a request of its own, and the channel
                // lookup may be one too.
                async let tokens = fetchFeedbackTokens(for: item)
                await waitForChannel(of: item)
                let fetched = await tokens
                guard !Task.isCancelled else { return }
                feedbackTokens = fetched
                shown = videoChannels.resolved(item)
            }
            .confirmationDialog(
                shown?.title ?? "",
                isPresented: Binding(
                    get: { shown != nil },
                    set: { isPresented in
                        if !isPresented {
                            shown = nil
                            item = nil
                        }
                    }
                ),
                titleVisibility: .visible,
                presenting: shown
            ) { video in
                // The channel actions need the channel, so a card whose channel couldn't be
                // found leaves them out — the message says why.
                if let channelID = video.channelID {
                    Button("Go to channel") { onOpenChannel(video) }
                    subscriptionButton(channelID: channelID, channelName: video.author)
                }
                if let token = feedbackTokens?.notInterested {
                    Button("Not interested") { dismiss(video, .video, token: token) }
                }
                if let token = feedbackTokens?.dontRecommendChannel {
                    Button("Don't recommend channel") { dismiss(video, .channel, token: token) }
                }
            } message: { video in
                if video.channelID == nil {
                    Text("Couldn't find which channel this video is from.")
                } else if !video.author.isEmpty {
                    Text(video.author)
                }
            }
    }

    /// Gives the card's channel lookup a moment to land before the menu goes up.
    ///
    /// A presented dialog doesn't redraw when what it was built from changes (verified on tvOS
    /// 26: a menu put up while the lookup was still out kept its "still looking" message after
    /// the answer had landed and the card behind it had drawn the channel's avatar), so the menu
    /// has to be right the moment it appears. The card asked as focus settled on it, so this normally returns at once; the
    /// wait only matters when that answer isn't in yet, or a failed one is worth another try now
    /// that someone wants it.
    ///
    /// Bounded, so a stalled request can't hold the menu back for as long as the network takes
    /// to give up on it. Polled, because the lookup's own task can't be stopped waiting on early.
    private func waitForChannel(of item: VideoItem) async {
        videoChannels.prefetch(item)
        let deadline = ContinuousClock.now + Self.lookupPatience
        while videoChannels.isLookingUp(item), ContinuousClock.now < deadline {
            guard (try? await Task.sleep(for: .milliseconds(50))) != nil else { return }
        }
    }

    /// The card's "see less" tokens, or `nil` when it offers none. A Home card's are a request
    /// away (see `VideoFeedback`), so this is bounded like the channel lookup: a slow answer
    /// costs the menu those two lines, not its appearance.
    private func fetchFeedbackTokens(for item: VideoItem) async -> FeedbackTokens? {
        guard let feedback = item.feedback else { return nil }
        let service = FeedbackService()
        return await withTaskGroup(of: FeedbackTokens?.self) { group in
            group.addTask {
                try? await authStore.authorized { token in
                    try await service.tokens(for: feedback, accessToken: token)
                }
            }
            group.addTask {
                try? await Task.sleep(for: Self.lookupPatience)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// Takes the card away at once and tells YouTube in the background, the way subscribing
    /// flips before its request goes out. A failed send leaves the card gone for this load —
    /// it was the user's choice either way, and it is rare enough not to warrant an error.
    private func dismiss(_ video: VideoItem, _ kind: VideoDismissal, token: String) {
        onDismiss(video, kind)
        Task {
            do {
                _ = try await authStore.authorized { accessToken in
                    try await FeedbackService().send(token, accessToken: accessToken)
                }
            } catch {
                #if DEBUG
                print("[VideoMenu] feedback for \(video.id) failed: \(error)")
                #endif
            }
        }
    }

    /// One button whose label is the action, not the state: "Subscribe" when the account doesn't
    /// follow the channel, "Unsubscribe" when it does.
    @ViewBuilder
    private func subscriptionButton(channelID: String, channelName: String) -> some View {
        let isSubscribed = subscriptions.isSubscribed(channelID)
        Button(
            isSubscribed ? "Unsubscribe" : "Subscribe",
            // Unsubscribing is the one that loses something, and it is directly above nothing
            // else — worth colouring so an overshoot is visible before it's confirmed.
            role: isSubscribed ? .destructive : nil
        ) {
            // The store flips its own state before the request goes out, so the menu closes
            // onto the new label rather than onto the old one for a round-trip.
            Task { await subscriptions.setSubscribed(!isSubscribed, channelID: channelID, using: authStore) }
        }
        // A press already in flight would otherwise let a second one send the opposite call.
        .disabled(subscriptions.isPending(channelID))
    }
}
