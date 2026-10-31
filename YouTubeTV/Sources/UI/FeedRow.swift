import SwiftUI

/// One shelf: a heading above a horizontally scrolling strip of cards.
///
/// Shared by Home and the channel screen — a channel's browse response comes back in the same
/// shelves as a feed's, so it gets the same row.
struct FeedRow: View {
    let section: FeedSection
    var onSelectVideo: (VideoItem) -> Void
    /// Long-pressing a card. The screen holding the row owns the menu, so one dialog serves the
    /// whole feed rather than one per card.
    var onLongPressVideo: (VideoItem) -> Void = { _ in }
    /// Fired as one of the last cards comes into view, so the row can grow before focus
    /// reaches its end.
    var onNeedMoreItems: () -> Void = {}
    /// Passed on to this row's first card — see `VideoCard.externalFocus`. Only the row a
    /// screen wants to be able to focus is given one.
    var firstCardFocus: FocusState<Bool>.Binding?
    /// Passed on to every card, keyed by `focusKey(row:video:)` — see `VideoCard.focusID`.
    var cardFocus: FocusState<String?>.Binding?
    /// A video to scroll into view, set just before the screen moves focus onto it.
    var scrollTarget: String?

    /// What a card answers to on `cardFocus`. Names the row as well as the video: Home lets the
    /// same video into two shelves, and a key shared by two cards can't say which to focus.
    static func focusKey(row: String, video: String) -> String { "\(row)/\(video)" }

    /// Start fetching more videos for a row once a card this close to its end comes into view.
    static let itemPrefetchDistance = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !section.title.isEmpty {
                Text(section.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Metrics.horizontalInset)
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    // Shorts tiles are narrow, so a video card's gap between them would read as a
                    // row of gaps. Kept proportional to the tile instead.
                    LazyHStack(spacing: section.isShorts ? Metrics.shortCardSpacing : Metrics.cardSpacing) {
                        ForEach(section.items) { item in
                            VideoCard(
                                item: item,
                                onLongPress: { onLongPressVideo(item) },
                                action: { onSelectVideo(item) },
                                externalFocus: item.id == section.items.first?.id
                                    ? firstCardFocus : nil,
                                focusID: cardFocus,
                                focusKey: Self.focusKey(row: section.id, video: item.id)
                            )
                            // In a LazyHStack this runs as the card scrolls in, which is the
                            // point: paging starts while cards are still to the right of it.
                            // The tail is a slice, so this stays cheap however long the row gets.
                            .onAppear {
                                if section.items.suffix(Self.itemPrefetchDistance).contains(item) {
                                    onNeedMoreItems()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.horizontalInset)
                    // Room for the focused card to grow without colliding with the heading above.
                    .padding(.vertical, 32)
                }
                // Without this the focus scale/shadow is cut off at the scroll view's edges.
                .scrollClipDisabled()
                // The card a screen is about to focus may not have been built yet — a lazy row
                // only makes the cards near what's on screen — so bring it in first.
                .onChange(of: scrollTarget) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id) } }
                }
            }
        }
        // Keeps left/right movement inside this row instead of jumping to a neighbouring one.
        .focusSection()
    }
}
