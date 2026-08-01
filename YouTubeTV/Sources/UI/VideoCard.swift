import SwiftUI
import UIKit

/// Layout constants shared by every screen that shows video cards, so the feed and the
/// search results line up on the same grid.
enum Metrics {
    /// Matches the tvOS title-safe inset used by headers and rows.
    static let horizontalInset: CGFloat = 80
    static let cardWidth: CGFloat = 420
    static let cardSpacing: CGFloat = 48
    /// Shorts tiles are portrait and carry no caption, so they're narrower than a video card and
    /// sit closer together. 240 at 9:16 comes out ~427 tall — near enough a video card's
    /// thumbnail-plus-caption height that a Shorts row doesn't tower over the rows around it.
    static let shortCardWidth: CGFloat = 240
    static let shortCardSpacing: CGFloat = 28
}

/// A single focusable video thumbnail card.
///
/// Draws two shapes from the same parts, chosen by `item.isShort`: a landscape card with its
/// channel/title/stats caption, or — for a Short — a portrait tile of nothing but the artwork,
/// matching the format the video was shot in. A Short carries neither title nor duration (it has
/// no running time to show), so on that tile the channel's avatar in the bottom-right corner,
/// which both shapes put in the same place, is the only thing over the image.
struct VideoCard: View {
    let item: VideoItem
    /// Holding Select on the focused card. The screen showing the cards puts a menu up —
    /// go to channel, subscribe or unsubscribe. Cards that aren't given one just play.
    var onLongPress: (() -> Void)?
    let action: () -> Void
    /// A focus handle owned by the screen showing the card, for the rare case where something
    /// else on that screen needs to put focus *here*. Home passes one to its first card so the
    /// news panel has somewhere definite to hand focus back to when it is dismissed; every
    /// other card is left to the focus engine.
    var externalFocus: FocusState<Bool>.Binding?

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

    /// How far the caption's text sits in from the card's edges. Applied to its lines one by one
    /// rather than to the caption as a whole, so the title can scroll the full width — see `title`.
    private static let captionInset: CGFloat = 14

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
                artwork

                // A Short's tile is the artwork and nothing else — no title, no stats.
                if !item.isShort {
                    caption
                }
            }
            // Fix the width here rather than outside the button. A wrapping title reports an
            // ideal width far wider than the card, and an outer frame doesn't clamp it — the
            // caption spilled past the thumbnail and dragged the panel out with it.
            .frame(width: item.isShort ? Metrics.shortCardWidth : Metrics.cardWidth)
            // Hung off the card's own bottom-right corner and trimmed by the clip below to about
            // three quarters of the circle.
            //
            // Behind the card where there's a caption for it to show through: a title long
            // enough to reach the corner then runs over the avatar rather than under it, and the
            // caption is the card's subject. A Short has no caption — only the opaque artwork,
            // which would hide it — so there it goes over the top instead. Either way it's
            // applied before the clip, which is what trims the disc.
            .background(alignment: .bottomTrailing) { if !item.isShort { channelAvatar } }
            .overlay(alignment: .bottomTrailing) { if item.isShort { channelAvatar } }
            // The one focus surface: a soft grey panel behind the whole card, in place of the
            // white outline and the white plate that used to sit under the caption. Applied
            // after the avatar so it stays behind it.
            .background(
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .fill(isFocused ? Color(white: 0.86) : Color.clear)
            )
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            // A Short's artwork covers that panel completely, so focus needs something the image
            // can't swallow. Drawn after the clip so the whole ring stays on the tile.
            .overlay { if item.isShort { focusRing } }
        }
        .buttonStyle(BareButtonStyle(onPressingChanged: pressingChanged))
        // Looks the channel's picture up the first time this card is drawn, if nothing already
        // knows it. The store dedupes by channel and remembers the answer across launches, so a
        // row of cards from one channel costs one request, once.
        .task(id: item.id) { await channelAvatars.resolve(item) }
        // Stated rather than left to SwiftUI to derive from the caption: a Short's tile has no
        // caption, so without this it would be an unlabelled button to VoiceOver and to the UI
        // tests, which identify a card by its label.
        .accessibilityLabel(accessibilityText)
        .focusEffectDisabled()
        .modifier(ExternalFocus(binding: externalFocus))
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

    /// The thumbnail box: 16:9 for a video, 9:16 for a Short, the full width of the card either
    /// way, with the image laid over it and cropped to fit. Sizing the `AsyncImage` itself
    /// instead would letterbox — the thumbnails YouTube serves aren't all the shape of the box
    /// they go in (`hqdefault.jpg` is 4:3 with black bars baked in) — and a fitted image leaves
    /// the card's edges showing through.
    private var artwork: some View {
        Color.gray.opacity(0.25)
            .aspectRatio(item.isShort ? 9.0 / 16.0 : 16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay { thumbnail }
            .overlay { preview }
            .overlay(alignment: .bottomTrailing) { durationBadge }
            .overlay(alignment: .bottom) { progressBar }
            // A video's bottom edge meets its caption and stays square there; a Short's is the
            // bottom of the card, so it takes the same radius as the rest of it. Matching the
            // panel's radius keeps thumbnail and caption reading as one surface.
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: Self.cornerRadius,
                    bottomLeadingRadius: item.isShort ? Self.cornerRadius : 0,
                    bottomTrailingRadius: item.isShort ? Self.cornerRadius : 0,
                    topTrailingRadius: Self.cornerRadius,
                    style: .continuous
                )
            )
    }

    /// The focus treatment for a Shorts tile, which has no caption and so no grey panel showing:
    /// a white edge around the artwork, drawn inside the card's own rounded shape.
    private var focusRing: some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .strokeBorder(isFocused ? Color.white : Color.clear, lineWidth: 4)
    }

    /// The artwork itself. `scaledToFill` overflows the box it sits in; the card's
    /// `clipShape` trims the overflow.
    @ViewBuilder
    private var thumbnail: some View {
        RemoteImage(url: item.thumbnailURL) { phase in
            switch phase {
            case .loaded(let image):
                image.resizable().scaledToFill()
            case .loading:
                ProgressView().tint(.white)
            case .failed:
                Image(systemName: "play.rectangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The video itself, playing silently over the thumbnail while this card is focused. Built
    /// only while focused and dropped on the way out — see `VideoPreview`, which owns the whole
    /// lifetime — so moving focus away stops playback and leaves the thumbnail showing again.
    @ViewBuilder
    private var preview: some View {
        if isFocused {
            VideoPreview(video: item)
        }
    }

    /// The channel's picture, hung off the card's bottom-right corner — over the caption on a
    /// video card, over the artwork on a Short, the same spot on both — so roughly three quarters
    /// of the circle shows and the rest runs off the card, which does the cropping.
    ///
    /// Sitting the centre `inset` from each edge leaves ~75% of the disc inside the card: the
    /// two clipped caps come to about a quarter of its area.
    @ViewBuilder
    private var channelAvatar: some View {
        if let url = channelAvatars.url(for: item) {
            // Scaled to the tile on a Short, which is a little over half a video card's width —
            // an 88pt disc there would read as the tile's subject rather than as a hint.
            let diameter: CGFloat = item.isShort ? 64 : 88
            let inset = diameter / 2 * 0.63

            // Nothing at all until the picture is there: no spinner and no grey disc. An avatar
            // that pops in late is fine, one that pulses a placeholder on every row draws the eye
            // away from the artwork — and the hairline below, drawn around an image that hadn't
            // arrived, was an empty ring hanging off the corner of every card.
            RemoteImage(url: url) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: diameter, height: diameter)
                        .clipShape(Circle())
                        // A hairline to hold the disc's edge against whichever surface is behind
                        // it — black unfocused, the grey focus panel otherwise. A Short's disc
                        // sits on the artwork whether the tile is focused or not, so there it
                        // stays light.
                        .overlay(
                            Circle().strokeBorder(
                                isFocused && !item.isShort
                                    ? Color.black.opacity(0.15) : Color.white.opacity(0.3),
                                lineWidth: 2)
                        )
                        // Held short of opaque so a long title running under it still reads. The
                        // avatar is a hint about the video, not a second subject.
                        .opacity(0.85)
                }
            }
            .frame(width: diameter, height: diameter)
            .offset(x: diameter / 2 - inset, y: diameter / 2 - inset)
        }
    }

    /// The running time, tucked into the corner of the thumbnail where YouTube itself puts it.
    /// Its own dark pill rather than bare text — thumbnails are arbitrary images, so nothing
    /// else guarantees contrast under it.
    ///
    /// Absent on a Short: it has no running time to badge (YouTube stamps those tiles with a
    /// Shorts glyph in place of one), and the tile is deliberately just the artwork.
    @ViewBuilder
    private var durationBadge: some View {
        if !item.duration.isEmpty && !item.isShort {
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
                    .padding(.horizontal, Self.captionInset)
            }

            // Inset from within, so the line it scrolls along is the whole width of the card —
            // see `title`. The channel and stats lines around it are inset here instead.
            title

            if !stats.isEmpty {
                Text(stats)
                    .font(Self.subtitleFont)
                    .foregroundStyle(isFocused ? Color.black.opacity(0.6) : Color.white.opacity(0.6))
                    .lineLimit(1)
                    .padding(.horizontal, Self.captionInset)
            }
        }
        // A stated width, rather than `maxWidth: .infinity`, which reports whatever the text under
        // it asks for when the width it is offered is unspecified — and the focused card's title
        // asks for its full unwrapped width (700pt and up). That measurement became the card's
        // width, so the card overflowed its own frame, sat off-centre inside it, and had the
        // right-hand side of the thumbnail — the preview playing in it — clipped away.
        //
        // The title box already keeps its two lines; the minimum height holds the rest of the
        // caption open too, so a card missing a channel or stats line doesn't sit shorter than its
        // neighbours and leave the row's focus panels ragged.
        .frame(width: Metrics.cardWidth, alignment: .topLeading)
        .frame(minHeight: 122, alignment: .topLeading)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    /// The video's title. On the focused card it runs on a single line and slides sideways, so a
    /// long title can be read in full instead of ending in an ellipsis; every other card keeps
    /// the quiet two-line wrap. Either way the box is `titleHeight` tall, so the swap doesn't
    /// move the stats line or change the card's height.
    ///
    /// The scrolling line runs the full width of the card, unlike the two lines bracketing it:
    /// it starts level with them, `captionInset` in, but slides right out to the card's edges
    /// rather than stopping short of them, so a long title has the whole tile to move through.
    @ViewBuilder
    private var title: some View {
        Group {
            if isFocused {
                ScrollingTitle(
                    text: item.title, font: Self.titleFont, leadingInset: Self.captionInset
                )
                .foregroundStyle(.black)
            } else {
                Text(item.title)
                    .font(Self.titleFont)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, Self.captionInset)
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

    /// What the card is called. The same three things the caption shows, in the order a card is
    /// read aloud — and on a Short, whatever of them the feed supplied, since none of it is on
    /// screen there.
    private var accessibilityText: String {
        [item.title, item.author, stats]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
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
    /// Where the text sits when it is standing still, measured from the left-hand edge of the
    /// box. Taken here rather than as padding around the whole view so that only the *text* is
    /// inset: the line it travels along still reaches both edges, and a title scrolling past
    /// runs off the card rather than stopping short of it.
    var leadingInset: CGFloat = 0

    /// Blank run between the end of the text and the start of the repeat, so the two copies
    /// read as one title coming round again rather than as a doubled word.
    private static let gap: CGFloat = 90

    /// Points per second. Quick enough that a long title comes round again while the card still
    /// has focus, and still readable at across-the-room distance.
    private static let speed: CGFloat = 95

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
        // The line the title has to fit in has to be measured from the box, not from what's in
        // it: a flexible frame around an oversized child reports the child's width, so measuring
        // the text's own container asked the title how wide it was and got the same number back
        // both times. `overflows` was then false however long the title, and it never scrolled.
        // A `GeometryReader` reports the width it is offered whatever it holds, which is the
        // question being asked.
        GeometryReader { proxy in
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
            // The inset moves the text, not the box: the offset the animation drives carries the
            // title straight past it and off the card's edge.
            .offset(x: leadingInset + offset)
            // Top-leading, so the single scrolling line sits where the first of the two wrapped
            // lines does on every other card and focus doesn't nudge the title down.
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            // What's left for the text once it is inset — a title that fits *that* stands still,
            // level with the channel and stats lines, rather than scrolling to no purpose.
            .onChange(of: proxy.size.width, initial: true) { _, width in
                containerWidth = width - leadingInset
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

/// Attaches a caller-owned focus handle to a card, when it was given one.
///
/// A conditional `.focused()` can't be written inline — the modifier needs a binding, not an
/// optional — so the choice is made here instead.
private struct ExternalFocus: ViewModifier {
    let binding: FocusState<Bool>.Binding?

    func body(content: Content) -> some View {
        if let binding {
            content.focused(binding)
        } else {
            content
        }
    }
}
