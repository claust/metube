import Foundation

/// A single video shown in the feed and passed to the player.
struct VideoItem: Identifiable, Hashable {
    let id: String          // YouTube videoId
    let title: String
    let author: String
    let thumbnailURL: URL?

    init(id: String, title: String, author: String = "", thumbnailURL: URL? = nil) {
        self.id = id
        self.title = title
        self.author = author
        self.thumbnailURL = thumbnailURL
    }
}
