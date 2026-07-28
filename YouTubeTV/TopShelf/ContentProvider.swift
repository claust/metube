import Foundation
import TVServices

/// Supplies the tiles tvOS draws above the app's icon when it is focused on the home screen's
/// top row.
///
/// This runs as a separate process that tvOS starts on its own schedule — including before the
/// app has been launched at all — with a short window to answer in. So it reads the snapshot
/// `TopShelfStore` holds in the shared app group and never touches the network: it has no OAuth
/// token to fetch a feed with, and a slow answer here is a blank strip on the home screen.
final class ContentProvider: TVTopShelfContentProvider {

    /// Heading above the tiles. Names where they came from rather than what they are, since the
    /// app's own icon is already sitting next to them saying which app this is.
    private static let collectionTitle = "From your feed"

    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        let videos = TopShelfStore.videos
        // `nil` content is how a provider says "nothing to show" — tvOS then falls back to the
        // plain focused icon. Handing back an empty collection instead draws an empty shelf.
        guard !videos.isEmpty else {
            completionHandler(nil)
            return
        }

        let collection = TVTopShelfItemCollection(items: videos.map(Self.item(for:)))
        collection.title = Self.collectionTitle
        completionHandler(TVTopShelfSectionedContent(sections: [collection]))
    }

    private static func item(for video: TopShelfVideo) -> TVTopShelfSectionedItem {
        let item = TVTopShelfSectionedItem(identifier: video.id)
        item.title = video.title
        // Feed thumbnails are 16:9, which is what `.hdtv` lays out for. Any other shape would
        // letterbox or crop them.
        item.imageShape = .hdtv
        // One URL for both scales: YouTube serves a single thumbnail per size rung, and the
        // ones the feed carries are already larger than a tile needs at 2x.
        item.setImageURL(video.thumbnailURL, for: .screenScale1x)
        item.setImageURL(video.thumbnailURL, for: .screenScale2x)

        // Both actions are the same URL: this app has no detail screen to display, so
        // selecting a tile and pressing play should each just open the video.
        let action = TopShelfLink.playURL(videoID: video.id).map(TVTopShelfAction.init(url:))
        item.displayAction = action
        item.playAction = action
        return item
    }
}
