import Foundation

/// Turns the `FEchannels` browse response — the "All subscriptions" grid — into
/// `SubscribedChannel`s.
///
/// Written the same way `VideoItemParser` is, and for the same reason: YouTube mixes cell shapes
/// freely and changes them without notice, so every known shape is collected in one pass rather
/// than one being tried as a fallback for another. What differs is how little is insisted on. A
/// video cell without a videoId is useless and gets dropped; a channel cell only has to yield a
/// `UC…` id, because that alone is enough to list the channel and open its page.
///
/// The fields themselves are read by shape rather than by path. A channel cell's title sits
/// somewhere different in each renderer, and its picture is the only image in the cell — there is
/// no video thumbnail to confuse it with — so the readers below look for the *kind* of value
/// wanted anywhere in the cell instead of naming a nesting that varies.
enum SubscribedChannelParser {

    /// Every channel cell in `json`, in document order, deduped by channel id.
    static func channels(in json: [String: Any]) -> [SubscribedChannel] {
        var results: [SubscribedChannel] = []
        var seen: Set<String> = []

        func walk(_ obj: Any) {
            if let dict = obj as? [String: Any] {
                for key in Self.cellKeys {
                    guard let cell = dict[key] as? [String: Any],
                        let channel = parse(cell), seen.insert(channel.id).inserted
                    else { continue }
                    results.append(channel)
                }
                // Sorted so a response that nests two cells under one dictionary — where there is
                // no document order to follow — always yields them the same way round.
                for key in dict.keys.sorted() { walk(dict[key] as Any) }
            } else if let array = obj as? [Any] {
                for value in array { walk(value) }
            }
        }
        walk(json)

        return results
    }

    /// The cell renderers a channel can arrive in. `tileRenderer` is what the TV client sends;
    /// the rest are the shapes the same grid uses on other clients, kept because this response is
    /// undocumented and the app would otherwise show an empty screen the day it changes.
    private static let cellKeys = [
        "tileRenderer",
        "gridChannelRenderer",
        "channelRenderer",
        "compactChannelRenderer",
        "lockupViewModel",
    ]

    /// Returns `nil` when the cell isn't a channel — the same renderers carry videos and
    /// playlists, and this grid is not guaranteed to hold only channels.
    private static func parse(_ cell: [String: Any]) -> SubscribedChannel? {
        // Where the cell says what it holds, believe it. Where it doesn't, the `UC…` id below is
        // the test: a video or playlist cell links its channel too, but this grid's cells *are*
        // channels, and a stray video cell would have been rejected here.
        if let contentType = cell["contentType"] as? String,
            contentType.contains("VIDEO") || contentType.contains("PLAYLIST")
                || contentType.contains("SHORT")
        {
            return nil
        }
        guard let id = channelID(in: cell) else { return nil }

        return SubscribedChannel(
            id: id,
            title: title(in: cell),
            avatarURL: avatar(in: cell),
            detail: detail(in: cell)
        )
    }

    /// The first `UC…` browse id in the cell. Channel ids are the only `browseId` beginning with
    /// `UC` — playlist (`VL`/`PL`) and feed (`FE`) endpoints share the field — which is what
    /// separates them, exactly as in `VideoItemParser`.
    private static func channelID(in cell: [String: Any]) -> String? {
        var found: String?
        func walk(_ obj: Any) {
            guard found == nil else { return }
            if let dict = obj as? [String: Any] {
                if let id = dict.string(at: "browseEndpoint/browseId"), id.hasPrefix("UC") {
                    found = id
                    return
                }
                for key in dict.keys.sorted() { walk(dict[key] as Any) }
            } else if let array = obj as? [Any] {
                for value in array { walk(value) }
            }
        }
        walk(cell)
        return found
    }

    /// The channel's name, from whichever of the shapes' title slots this cell happens to use.
    /// Empty when none of them carried one, which the screen copes with rather than dropping the
    /// channel over.
    private static func title(in cell: [String: Any]) -> String {
        let paths = [
            "metadata/tileMetadataRenderer/title",
            "metadata/lockupMetadataViewModel/title",
            "title",
            "headline",
            "displayName",
        ]
        for path in paths {
            if let text = text(cell.value(at: path)), !text.isEmpty { return text }
        }
        return ""
    }

    /// The channel's picture.
    ///
    /// Every image in a channel cell is that channel's avatar — unlike a video cell, there is no
    /// thumbnail to tell it apart from — so this collects the cell's image lists and takes the
    /// best entry. `avatarURL(from:)`, which the video cells use, recognises avatars by their
    /// serving host and asks the CDN for a size worth drawing on a TV; the widest raw image is
    /// the fallback for a cell served from somewhere it doesn't know.
    private static func avatar(in cell: [String: Any]) -> URL? {
        var images: [[String: Any]] = []
        func walk(_ obj: Any) {
            if let dict = obj as? [String: Any] {
                for key in ["thumbnails", "sources"] {
                    if let list = dict[key] as? [[String: Any]] { images.append(contentsOf: list) }
                }
                for value in dict.values { walk(value) }
            } else if let array = obj as? [Any] {
                for value in array { walk(value) }
            }
        }
        walk(cell)

        guard !images.isEmpty else { return nil }
        return avatarURL(from: images) ?? largestThumbnailURL(images)
    }

    /// The line under the name: a subscriber count where the cell gives one, and a video count
    /// otherwise. Both arrive already abbreviated ("1.2M subscribers"), so they are taken as
    /// text and shown verbatim.
    ///
    /// Which slot holds it varies by shape — named fields on the older renderers, an anonymous
    /// subtitle line on a tile — so everything text-shaped in the cell is flattened to fragments
    /// and classified by what it says, the way `VideoItemParser` reads a video's subtitle.
    private static func detail(in cell: [String: Any]) -> String {
        var subscribers = ""
        var videos = ""

        for fragment in subtitleFragments(in: cell) {
            if fragment.range(of: "subscriber", options: .caseInsensitive) != nil {
                if subscribers.isEmpty { subscribers = fragment }
            } else if fragment.range(of: "video", options: .caseInsensitive) != nil {
                if videos.isEmpty { videos = fragment }
            }
        }

        return subscribers.isEmpty ? videos : subscribers
    }

    /// Every piece of subtitle text in the cell, split on the bullets YouTube joins several
    /// values with. The title is skipped: a channel called "Video Game Reviews" would otherwise
    /// read as a video count.
    private static func subtitleFragments(in cell: [String: Any]) -> [String] {
        let name = title(in: cell)
        var fragments: [String] = []

        func collect(_ value: Any?) {
            guard let text = text(value), !text.isEmpty, text != name else { return }
            fragments.append(contentsOf: split(text))
        }

        for key in ["subscriberCountText", "videoCountText", "subtitle"] {
            collect(cell[key])
        }
        // A tile's counts sit in its metadata lines, unnamed, the same place a video card's
        // channel and view count come from.
        let lines = cell.value(at: "metadata/tileMetadataRenderer/lines") as? [[String: Any]] ?? []
        for item in lines.flatMap({ ($0.value(at: "lineRenderer/items") as? [[String: Any]]) ?? [] }) {
            collect(item.value(at: "lineItemRenderer/text"))
        }
        // And a lockup's in its metadata rows, likewise unnamed.
        let rows =
            cell.value(
                at: "metadata/lockupMetadataViewModel/metadata/contentMetadataViewModel/metadataRows")
            as? [[String: Any]] ?? []
        for part in rows.flatMap({ ($0["metadataParts"] as? [[String: Any]]) ?? [] }) {
            collect(part["text"])
        }

        return fragments
    }

    private static func split(_ text: String) -> [String] {
        text.split(whereSeparator: { "•·|".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// InnerTube's text objects and the view models' plain strings, read the same way: the
    /// renderers wrap text in `simpleText`/`runs`, the view models in `{"content": "…"}`, and a
    /// few fields are simply a string.
    private static func text(_ value: Any?) -> String? {
        if let string = value as? String { return string.trimmingCharacters(in: .whitespaces) }
        if let text = innerTubeText(value) { return text.trimmingCharacters(in: .whitespaces) }
        if let content = (value as? [String: Any])?["content"] as? String {
            return content.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
