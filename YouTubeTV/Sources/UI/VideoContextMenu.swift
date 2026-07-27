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

    func body(content: Content) -> some View {
        content.confirmationDialog(
            item?.title ?? "",
            isPresented: Binding(
                get: { item != nil },
                set: { isPresented in
                    if !isPresented { item = nil }
                }
            ),
            titleVisibility: .visible,
            presenting: item
        ) { video in
            // Both actions are about the channel, so a card that never linked one has nothing
            // to offer — say so rather than showing a menu of one greyed-out line.
            if let channelID = video.channelID {
                Button("Go to channel") { onOpenChannel(video) }
                subscriptionButton(channelID: channelID, channelName: video.author)
            }
        } message: { video in
            if video.channelID == nil {
                Text("This video doesn't say which channel it's from.")
            } else if !video.author.isEmpty {
                Text(video.author)
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
