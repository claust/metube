import SwiftUI

extension View {
    /// The menu a long press on a card puts up: go to the uploader's channel, and subscribe or
    /// unsubscribe depending on where the account stands with it.
    ///
    /// Attached once per screen and driven by the card the user pressed, rather than one menu
    /// per card: a feed holds dozens of cards, and only one menu is ever open.
    ///
    /// A `confirmationDialog` rather than a `contextMenu`, matching the profile bar's menu — on
    /// a d-pad these read as one full-screen list of choices, with Menu backing out of them.
    func videoMenu(for item: Binding<VideoItem?>, onOpenChannel: @escaping (VideoItem) -> Void)
        -> some View
    {
        modifier(VideoMenu(item: item, onOpenChannel: onOpenChannel))
    }
}

private struct VideoMenu: ViewModifier {
    @Binding var item: VideoItem?
    let onOpenChannel: (VideoItem) -> Void

    @EnvironmentObject private var authStore: AuthStore
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @EnvironmentObject private var videoChannels: VideoChannelStore

    /// The card the dialog is showing: `item` with its channel filled in, set once the lookup
    /// has had its chance — see `waitForChannel(of:)`.
    @State private var shown: VideoItem?

    /// The longest the menu holds back for a channel lookup still under way.
    private static let lookupPatience = Duration.seconds(2)

    func body(content: Content) -> some View {
        content
            .task(id: item?.id) {
                guard let item else { return }
                await waitForChannel(of: item)
                guard !Task.isCancelled else { return }
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
                // Both actions are about the channel, so a card whose channel couldn't be found
                // has nothing to offer — say so rather than showing a menu of one greyed-out line.
                if let channelID = video.channelID {
                    Button("Go to channel") { onOpenChannel(video) }
                    subscriptionButton(channelID: channelID, channelName: video.author)
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
