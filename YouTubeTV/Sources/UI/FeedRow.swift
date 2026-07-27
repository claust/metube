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

            ScrollView(.horizontal) {
                LazyHStack(spacing: Metrics.cardSpacing) {
                    ForEach(section.items) { item in
                        VideoCard(
                            item: item,
                            onLongPress: { onLongPressVideo(item) },
                            action: { onSelectVideo(item) }
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
        }
        // Keeps left/right movement inside this row instead of jumping to a neighbouring one.
        .focusSection()
    }
}
