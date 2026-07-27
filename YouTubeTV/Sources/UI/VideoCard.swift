import SwiftUI

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
    let action: () -> Void

    @EnvironmentObject private var watchProgress: WatchProgressStore
    @EnvironmentObject private var channelAvatars: ChannelAvatarStore
    @FocusState private var isFocused: Bool

    /// Shared by the focus panel and the thumbnail's top corners.
    private static let cornerRadius: CGFloat = 16

    /// The channel line and the stats line bracket the title in the same small type, so the
    /// caption reads as one block with the title as its only emphasis.
    private static let subtitleFont: Font = .system(size: 22, weight: .medium)

    var body: some View {
        Button(action: action) {
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
        .buttonStyle(BareButtonStyle())
        // Looks the channel's picture up the first time this card is drawn, if nothing already
        // knows it. The store dedupes by channel and remembers the answer across launches, so a
        // row of cards from one channel costs one request, once.
        .task(id: item.id) { await channelAvatars.resolve(item) }
        .focusEffectDisabled()
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.08 : 1.0)
        .shadow(color: .black.opacity(isFocused ? 0.6 : 0), radius: 20)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
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

            Text(item.title)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(isFocused ? .black : .white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if !stats.isEmpty {
                Text(stats)
                    .font(Self.subtitleFont)
                    .foregroundStyle(isFocused ? Color.black.opacity(0.6) : Color.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
        // Room for the channel line, two title lines and the stats line, so a short title
        // doesn't shrink the card below its neighbours and leave the row's focus panels ragged.
        .frame(maxWidth: .infinity, minHeight: 122, alignment: .topLeading)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
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

/// Renders a button as nothing but its label.
///
/// Even `.plain` lifts a focused tvOS button onto a system platter — a padded surface, drawn
/// wider than the card, that also washes the content with a specular highlight. That platter
/// was the margin around the thumbnail. With this style the card's own grey panel is the whole
/// focus treatment, so the artwork reaches its edges.
private struct BareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
