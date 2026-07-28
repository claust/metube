import SwiftUI
import UIKit

/// Layout constants shared by every screen that shows video cards, so the feed and the
/// search results line up on the same grid.
enum Metrics {
    /// Matches the tvOS title-safe inset used by headers and rows.
    static let horizontalInset: CGFloat = 80
    static let cardWidth: CGFloat = 420
    static let cardSpacing: CGFloat = 48
}

/// A single focusable video thumbnail card.
struct VideoCard: View {
    let item: VideoItem
    /// Holding Select on the focused card. The screen showing the cards puts a menu up —
    /// go to channel, subscribe or unsubscribe. Cards that aren't given one just play.
    var onLongPress: (() -> Void)?
    let action: () -> Void

    @EnvironmentObject private var watchProgress: WatchProgressStore
    @EnvironmentObject private var channelAvatars: ChannelAvatarStore
    @FocusState private var isFocused: Bool

    /// Counts out the hold while Select is down, and is cancelled by the release.
    @State private var holdTask: Task<Void, Never>?

    /// Whether the press currently in progress has already become a long press. A tvOS Button
    /// still fires on release, so without this the menu would open and the player would come
    /// up over it. Cleared at the start of every press, so a hold whose release never reached
    /// the button can't swallow the next one.
    @State private var didLongPress = false

    /// How long Select has to be held for the menu rather than the video.
    private static let longPressDuration = Duration.milliseconds(500)

    /// Shared by the focus panel and the thumbnail's top corners.
    private static let cornerRadius: CGFloat = 16

    /// The channel line and the stats line bracket the title in the same small type, so the
    /// caption reads as one block with the title as its only emphasis.
    private static let subtitleFont: Font = .system(size: 22, weight: .medium)

    /// The title's own type, the card's only emphasis.
    private static let titleSize: CGFloat = 30
    private static let titleFont: Font = .system(size: titleSize, weight: .semibold)

    /// The title box is always two lines tall, whether it holds a wrapped title or the focused
    /// card's single scrolling line, so taking focus doesn't resize the caption under the
    /// thumbnail. Measured from the font rather than guessed, so it still fits if the size changes.
    private static let titleHeight: CGFloat =
        (UIFont.systemFont(ofSize: titleSize, weight: .semibold).lineHeight * 2).rounded(.up)

    var body: some View {
        Button(action: play) {
            // No spacing or outer padding: the thumbnail runs the full width of the focus
            // panel and butts against its top and side edges, so focusing genuinely enlarges
            // the image rather than framing it.
            VStack(alignment: .leading, spacing: 0) {
                // A 16:9 box the full width of the card, with the image laid over it and
                // cropped to fit. Sizing the AsyncImage itself instead would letterbox: the
                // thumbnails YouTube serves aren't all 16:9 (`hqdefault.jpg` is 4:3 with black
                // bars baked in), and a fitted image leaves the card's edges showing through.
                Color.gray.opacity(0.25)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay { thumbnail }
                    .overlay(alignment: .bottomTrailing) { durationBadge }
                    .overlay(alignment: .bottom) { progressBar }
                    // Only the top corners are rounded — the bottom edge meets the caption,
                    // and matching the panel's radius keeps the two reading as one surface.
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: Self.cornerRadius,
                            topTrailingRadius: Self.cornerRadius,
                            style: .continuous
                        )
                    )

                caption
            }
            // Fix the width here rather than outside the button. A wrapping title reports an
            // ideal width far wider than the card, and an outer frame doesn't clamp it — the
            // caption spilled past the thumbnail and dragged the panel out with it.
            .frame(width: Metrics.cardWidth)
            // Hung off the card's own bottom-right corner and trimmed by the clip below to about
            // three quarters of the circle. A background rather than an overlay: the caption is
            // the card's subject, so a title long enough to reach the corner runs over the
            // avatar rather than under it.
            .background(alignment: .bottomTrailing) { channelAvatar }
            // The one focus surface: a soft grey panel behind the whole card, in place of the
            // white outline and the white plate that used to sit under the caption. Applied
            // after the avatar so it stays behind it.
            .background(
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .fill(isFocused ? Color(white: 0.86) : Color.clear)
            )
            .clipShape(
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        }
        .buttonStyle(BareButtonStyle(onPressingChanged: pressingChanged))
        // Looks the channel's picture up the first time this card is drawn, if nothing already
        // knows it. The store dedupes by channel and remembers the answer across launches, so a
        // row of cards from one channel costs one request, once.
        .task(id: item.id) { await channelAvatars.resolve(item) }
        .focusEffectDisabled()
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.08 : 1.0)
        .shadow(color: .black.opacity(isFocused ? 0.6 : 0), radius: 20)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
        // Nothing is left holding the card once it scrolls out of a lazy row, so a hold that
        // was in progress would otherwise open a menu for a card nobody is on any more.
        .onDisappear { holdTask?.cancel() }
    }

    /// Select going down and coming up on the focused card.
    ///
    /// This is the button's own pressed state rather than a long-press gesture: on tvOS a
    /// Button consumes the Select press itself, so a gesture attached to it never recognizes —
    /// the hold silently arrives as an ordinary tap on release (verified on-device). The
    /// pressed state is the same signal the button acts on, so it can't be missed the same way.
    private func pressingChanged(_ isPressing: Bool) {
        holdTask?.cancel()
        guard isPressing, onLongPress != nil else { return }
        didLongPress = false
        holdTask = Task {
            guard (try? await Task.sleep(for: Self.longPressDuration)) != nil else { return }
            // The menu opens under the finger, while Select is still down — which is what makes
            // it read as a long press rather than as a delayed reaction to letting go.
            didLongPress = true
            onLongPress?()
        }
    }

    /// Opens the video, unless this press already opened the card's menu.
    private func play() {
        guard !didLongPress else { return }
        action()
    }

    /// The artwork itself. `scaledToFill` overflows the 16:9 box it sits in; the card's
    /// `clipShape` trims the overflow.
    @ViewBuilder
    private var thumbnail: some View {
        AsyncImage(url: item.thumbnailURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .empty:
                ProgressView().tint(.white)
            case .failure:
                Image(systemName: "play.rectangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            @unknown default:
                Color.clear
            }
        }
    }

    /// The channel's picture, hung off the card's bottom-right corner — below the thumbnail,
    /// over the caption — so roughly three quarters of the circle shows and the rest runs off
    /// the card, which does the cropping.
    ///
    /// Sitting the centre `inset` from each edge leaves ~75% of the disc inside the card: the
    /// two clipped caps come to about a quarter of its area.
    @ViewBuilder
    private var channelAvatar: some View {
        if let url = channelAvatars.url(for: item) {
            let diameter: CGFloat = 88
            let inset = diameter / 2 * 0.63

            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                // No spinner and no grey disc: an avatar that pops in late is fine, one that
                // pulses a placeholder on every row draws the eye away from the artwork.
                Color.clear
            }
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())
            // A hairline to hold the disc's edge against whichever surface is behind it —
            // black unfocused, the grey focus panel otherwise.
            .overlay(
                Circle().strokeBorder(
                    isFocused ? Color.black.opacity(0.15) : Color.white.opacity(0.3),
                    lineWidth: 2)
            )
            // Held short of opaque so a long title running under it still reads. The avatar
            // is a hint about the video, not a second subject.
            .opacity(0.85)
            .offset(x: diameter / 2 - inset, y: diameter / 2 - inset)
        }
    }

    /// The running time, tucked into the corner of the thumbnail where YouTube itself puts it.
    /// Its own dark pill rather than bare text — thumbnails are arbitrary images, so nothing
    /// else guarantees contrast under it.
    @ViewBuilder
    private var durationBadge: some View {
        if !item.duration.isEmpty {
            Text(item.duration)
                .font(.system(size: 18, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.black.opacity(0.65)))
                .padding(10)
        }
    }

    /// How far the user got last time: a red line along the bottom edge of the thumbnail, on a
    /// dark track so the remainder reads as unwatched over a light image. Inside the artwork
    /// rather than under it, matching where YouTube itself draws it. Absent until there's
    /// something to show, so an unwatched card is unchanged.
    @ViewBuilder
    private var progressBar: some View {
        if let fraction = watchProgress.fraction(for: item) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Color.black.opacity(0.55)
                    Color.red
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 8)
        }
    }

    /// Channel, then title, then views and age on a line of their own. Text goes black on focus,
    /// against the grey panel behind the card — white-on-black beside a lit thumbnail is the
    /// hardest thing on the row to read.
    private var caption: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !item.author.isEmpty {
                Text(item.author)
                    .font(Self.subtitleFont)
                    .foregroundStyle(isFocused ? Color.black.opacity(0.6) : Color.white.opacity(0.6))
                    .lineLimit(1)
            }

            title

            if !stats.isEmpty {
                Text(stats)
                    .font(Self.subtitleFont)
                    .foregroundStyle(isFocused ? Color.black.opacity(0.6) : Color.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
        // The title box already keeps its two lines; this holds the rest of the caption open too,
        // so a card missing a channel or stats line doesn't sit shorter than its neighbours and
        // leave the row's focus panels ragged.
        .frame(maxWidth: .infinity, minHeight: 122, alignment: .topLeading)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    /// The video's title. On the focused card it runs on a single line and slides sideways, so a
    /// long title can be read in full instead of ending in an ellipsis; every other card keeps
    /// the quiet two-line wrap. Either way the box is `titleHeight` tall, so the swap doesn't
    /// move the stats line or change the card's height.
    @ViewBuilder
    private var title: some View {
        Group {
            if isFocused {
                ScrollingTitle(text: item.title, font: Self.titleFont)
                    .foregroundStyle(.black)
            } else {
                Text(item.title)
                    .font(Self.titleFont)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: Self.titleHeight, alignment: .topLeading)
    }

    /// "1.2M views · 3 days ago", dropping whichever parts the feed didn't supply. The running
    /// time isn't here — it has its own badge on the thumbnail.
    private var stats: String {
        let age = item.publishedAt.flatMap { RelativeTime.string(for: $0) } ?? ""
        return [item.viewCount, age]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// One line of text that slides left at a constant speed when it is too wide to fit, and sits
/// still when it isn't.
///
/// Two copies of the text with a fixed gap between them, shifted by exactly one copy plus one
/// gap: when the animation loops, the second copy is standing where the first began, so the
/// text reappears without a seam and the motion never pauses or jumps back. A single linear
/// animation runs the whole loop — nothing per-frame, no timer — which is what keeps it smooth.
private struct ScrollingTitle: View {
    let text: String
    let font: Font

    /// Blank run between the end of the text and the start of the repeat, so the two copies
    /// read as one title coming round again rather than as a doubled word.
    private static let gap: CGFloat = 90

    /// Points per second. Slow enough to read at across-the-room distance.
    private static let speed: CGFloat = 60

    /// The title holds still this long before it starts moving, so the opening words can be read
    /// at the moment the card takes focus rather than sliding out from under the eye.
    private static let startDelay = Duration.milliseconds(900)

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    /// A hair of slack: a title that fills the line to the pixel shouldn't crawl.
    private var overflows: Bool { textWidth > containerWidth + 1 }

    /// How far the first copy travels before the second one has taken its place.
    private var shift: CGFloat { textWidth + Self.gap }

    var body: some View {
        HStack(spacing: Self.gap) {
            line
                .background {
                    GeometryReader { proxy in
                        Color.clear.onChange(of: proxy.size.width, initial: true) { _, width in
                            textWidth = width
                        }
                    }
                }

            // Only drawn when it can actually be reached, so a short title isn't quietly
            // rendered twice off the right-hand edge.
            // Hidden from accessibility: it's the same title over again, and the card's label
            // (which UI tests use as the card's identity) shouldn't say it twice.
            if overflows { line.accessibilityHidden(true) }
        }
        .offset(x: offset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size.width, initial: true) { _, width in
                    containerWidth = width
                }
            }
        }
        .clipped()
        // Restarts whenever either measurement lands — the first pass runs with both at zero.
        .task(id: [textWidth, containerWidth]) {
            offset = 0
            guard overflows else { return }
            guard (try? await Task.sleep(for: Self.startDelay)) != nil else { return }
            withAnimation(
                .linear(duration: Double(shift / Self.speed)).repeatForever(autoreverses: false)
            ) {
                offset = -shift
            }
        }
    }

    /// The text itself, laid out at its natural width however narrow the card is.
    private var line: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .fixedSize()
    }
}

/// Renders a button as nothing but its label.
///
/// Even `.plain` lifts a focused tvOS button onto a system platter — a padded surface, drawn
/// wider than the card, that also washes the content with a specular highlight. That platter
/// was the margin around the thumbnail. With this style the card's own grey panel is the whole
/// focus treatment, so the artwork reaches its edges.
/// It also reports the press itself, which is the only way the card sees Select go down: the
/// button's action arrives on release, and a long-press gesture on tvOS never arrives at all.
private struct BareButtonStyle: ButtonStyle {
    var onPressingChanged: ((Bool) -> Void)?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in
                onPressingChanged?(isPressed)
            }
    }
}
