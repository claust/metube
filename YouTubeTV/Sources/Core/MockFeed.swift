#if DEBUG
import Foundation

/// A canned feed for looking at layout without signing in.
///
/// Debug builds launched with `-mockFeed` skip both the login screen and the network, and
/// render these shelves instead — which is what makes it possible to screenshot a card change
/// on the simulator. Thumbnails are real ytimg URLs so the tiles have actual images in them.
enum MockFeed {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-mockFeed")
    }

    static var sections: [FeedSection] {
        [
            FeedSection(title: "Recommended", items: items(offset: 0)),
            FeedSection(title: "Watch it again", items: items(offset: 4)),
        ]
    }

    private struct Sample {
        let id: String
        let title: String
        let author: String
        let views: String
        let duration: String
        /// How long ago it was "published", in seconds — spread across the whole relative-time
        /// ladder so every branch of `RelativeTime.string(for:)` shows up on screen.
        let age: TimeInterval
    }

    private static let samples = [
        Sample(
            id: "dQw4w9WgXcQ", title: "A fairly long video title that wraps onto two lines",
            author: "Rick Astley", views: "1.4B views", duration: "3:33", age: 90),
        Sample(
            id: "9bZkp7q19f0", title: "Short title",
            author: "officialpsy", views: "5.3B views", duration: "4:13", age: 60 * 45),
        Sample(
            id: "kJQP7kiw5Fk", title: "Another title that is medium length here",
            author: "Luis Fonsi", views: "8.7B views", duration: "4:42", age: 3600 * 6),
        Sample(
            id: "JGwWNGJdvx8", title: "Something recent",
            author: "Ed Sheeran", views: "6.2B views", duration: "4:24", age: 86400 * 3),
        Sample(
            id: "OPf0YbXqDm0", title: "A title of about average length for a video",
            author: "Mark Ronson", views: "1.9B views", duration: "4:31", age: 86400 * 12),
        Sample(
            id: "CevxZvSJLk8", title: "Roar",
            author: "Katy Perry", views: "4.1B views", duration: "3:44", age: 86400 * 90),
        Sample(
            id: "hT_nvWreIhg", title: "Counting Stars",
            author: "OneRepublic", views: "4.6B views", duration: "4:17", age: 86400 * 400),
        Sample(
            id: "YQHsXMglC9A", title: "Hello",
            author: "Adele", views: "3.3B views", duration: "6:07", age: 86400 * 1200),
    ]

    private static func items(offset: Int) -> [VideoItem] {
        let now = Date()
        return (0..<4).map { index in
            let sample = samples[(offset + index) % samples.count]
            return VideoItem(
                id: "\(sample.id)-\(offset)-\(index)",
                title: sample.title,
                author: sample.author,
                thumbnailURL: URL(string: "https://i.ytimg.com/vi/\(sample.id)/hqdefault.jpg"),
                publishedAt: now.addingTimeInterval(-sample.age),
                viewCount: sample.views,
                duration: sample.duration
            )
        }
    }
}
#endif
