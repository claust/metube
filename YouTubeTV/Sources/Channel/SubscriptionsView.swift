import SwiftUI

/// The menu's Subscriptions screen: every channel the account follows, as a grid of pictures,
/// each one a way into that channel's page.
///
/// A grid of avatars rather than a list of rows because that is what the screen is *for*: you
/// come here knowing which channel you want, and a picture is quicker to find among a hundred
/// than a name is. The name and one line of detail sit under each picture for the channels whose
/// artwork doesn't announce them.
///
/// The list lives in `SubscriptionStore` rather than here, so arriving from the menu draws
/// whatever the feed's own refresh already loaded instead of opening on a spinner — see
/// `SubscriptionStore.channels`.
struct SubscriptionsView: View {
    /// Bumped by the shell when the menu picks this section. The page answers by taking focus,
    /// which is what closes the menu behind the press — the same handshake Home does.
    var focusRequest: Int = 0

    /// Opens a channel's page. The shell pushes it onto the same navigation stack a card's
    /// "Go to channel" uses, so the two arrive at exactly the same screen.
    var onOpenChannel: (SubscribedChannel) -> Void

    @EnvironmentObject private var authStore: AuthStore
    @EnvironmentObject private var subscriptions: SubscriptionStore

    /// What focus can be on. The header is a target in its own right so that the empty, loading
    /// and failed screens — none of which have a tile — still have somewhere to put focus:
    /// without one, arriving here would leave the focus engine holding nothing and the menu
    /// would never close.
    private enum Target: Hashable {
        case page
        case channel(String)
    }

    @FocusState private var focus: Target?

    @State private var isLoading = false
    @State private var errorMessage: String?

    /// Channels in the order `FEchannels` returned them — alphabetical in every response seen so
    /// far, though nothing promises that. Left exactly as it arrived rather than re-sorted here,
    /// so the grid matches the list YouTube's own clients show.
    private var channels: [SubscribedChannel] { subscriptions.channels }

    /// Six across at 1080p, which puts a comfortable gap between avatars without the names
    /// under them having to wrap for any but the longest channel.
    private static let columns = 6
    private static let avatarSize: CGFloat = 160
    private static let columnSpacing: CGFloat = 48
    private static let rowSpacing: CGFloat = 56

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                header

                content
                    .padding(.top, 56)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.horizontalInset)
            .padding(.vertical, 80)
        }
        // The page is one focus region and the menu is another, so a press up from a tile finds
        // the row above rather than stepping out sideways into the menu.
        .focusSection()
        .task {
            if channels.isEmpty { await load() }
        }
        // The same delay the feed's handoffs need: the page has to be on screen before there is
        // anything to put focus on.
        .task(id: focusRequest) {
            guard focusRequest > 0 else { return }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            focus = channels.first.map { .channel($0.id) } ?? .page
        }
        // Focus landed on the header because the grid wasn't there yet. Hand it to the first
        // tile now that it is — but only from the header, never off a tile the user has since
        // moved to, which a refresh mid-browse would otherwise yank them off.
        .onChange(of: channels.first?.id) { _, first in
            guard focus == .page, let first else { return }
            focus = .channel(first)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Subscriptions")
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(.white)

            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.white.opacity(0.5))
        }
        // Focusable so the screens with no tiles still have a home for focus; see `Target`.
        .focusable()
        .focused($focus, equals: .page)
    }

    private var subtitle: String {
        if isLoading && channels.isEmpty { return "Loading your channels…" }
        if errorMessage != nil && channels.isEmpty { return "Couldn't load your channels." }
        switch channels.count {
        case 0: return "You aren't subscribed to any channels yet."
        case 1: return "1 channel"
        case let count: return "\(count) channels"
        }
    }

    @ViewBuilder
    private var content: some View {
        if !channels.isEmpty {
            grid
        } else if isLoading {
            ProgressView()
                .tint(.white)
        } else if let errorMessage {
            failure(errorMessage)
        } else {
            Text("Subscribe to a channel and it will show up here.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var grid: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: Self.columnSpacing, alignment: .top),
                count: Self.columns),
            spacing: Self.rowSpacing
        ) {
            ForEach(channels) { channel in
                SubscriptionTile(
                    channel: channel,
                    avatarSize: Self.avatarSize,
                    action: { onOpenChannel(channel) }
                )
                .focused($focus, equals: .channel(channel.id))
            }
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
            Button("Try again") {
                Task { await load() }
            }
            .font(.headline)
        }
    }

    @MainActor
    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let loaded = try await subscriptions.reload(using: authStore)
            // `false` means nobody is signed in, or the load was called off — neither of which is
            // an empty subscription list, and the empty copy would be the screen answering a
            // question it never got an answer to. A cancelled load needs no message: the screen
            // is being left. Signing out swaps this whole screen for the login one, so in
            // practice this is the case where the token could not be renewed.
            if !loaded, !Task.isCancelled, channels.isEmpty {
                errorMessage = "Your account couldn't be reached."
            }
        } catch {
            // A cancelled load is the screen being left, not a failure to report.
            if isCancellation(error) { return }
            errorMessage = error.localizedDescription
        }
    }
}

/// One channel: its picture, its name, and whatever the list said about it.
///
/// The picture is the tile. Focus grows the whole thing and rings the avatar, rather than
/// putting a panel behind it the way a video card does — a circle in a rectangle of highlight
/// reads as a badge stuck on the screen, and these tiles have no artwork to fill one.
private struct SubscriptionTile: View {
    let channel: SubscribedChannel
    let avatarSize: CGFloat
    let action: () -> Void

    @EnvironmentObject private var channelAvatars: ChannelAvatarStore
    @FocusState private var isFocused: Bool

    /// The list's own picture where it gave one, and the cache the feed's cards fill otherwise —
    /// which, for a channel whose videos are on Home, is already warm.
    private var avatarURL: URL? {
        channel.avatarURL ?? channelAvatars.url(forChannel: channel.id)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 16) {
                avatar

                Text(channel.displayName)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(isFocused ? .white : .white.opacity(0.75))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    // Two lines' worth whether or not the name needs both, so a wrapped name
                    // doesn't push its neighbours' detail lines out of alignment.
                    .frame(height: 62, alignment: .top)

                if !channel.detail.isEmpty {
                    Text(channel.detail)
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PlainTileButtonStyle())
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.08 : 1)
        .animation(.easeOut(duration: 0.15), value: isFocused)
        // Looks the picture up the first time the tile is drawn, if nothing knows it yet. The
        // store dedupes by channel and remembers the answer across launches, so a screenful of
        // tiles costs one request per channel, once ever.
        .task(id: channel.id) {
            guard channel.avatarURL == nil else { return }
            await channelAvatars.resolve(channelID: channel.id)
        }
        // The button's label is a stack of three views, which VoiceOver and the UI tests would
        // otherwise read out as three separate things.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(channel.displayName)
    }

    private var avatar: some View {
        RemoteImage(url: avatarURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                // A flat disc rather than a spinner: a screenful of them would be a screenful of
                // motion, and the picture usually lands before the eye reaches the tile.
                Color(white: 0.22)
            }
        }
        .frame(width: avatarSize, height: avatarSize)
        .clipShape(Circle())
        .overlay {
            Circle().strokeBorder(.white, lineWidth: isFocused ? 6 : 0)
        }
    }
}

/// Draws the tile and nothing else. Every stock tvOS button style adds a plate and a lift of its
/// own, which fights the ring and the scale the tile applies for itself.
private struct PlainTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
