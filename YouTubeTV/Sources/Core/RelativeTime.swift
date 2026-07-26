import Foundation

/// Formats and parses "how long ago" strings for feed tiles.
///
/// InnerTube hands us the age as already-rendered text ("3 days ago"), never as a timestamp,
/// so the round trip is: parse that text back into an approximate `Date` at fetch time, then
/// format it ourselves for display. Doing it that way means the age keeps ticking while the
/// app stays open, and every tile reads the same regardless of which renderer it came from.
enum RelativeTime {

    // MARK: - Formatting

    private static let minute: TimeInterval = 60
    private static let hour: TimeInterval = 60 * minute
    private static let day: TimeInterval = 24 * hour
    private static let week: TimeInterval = 7 * day
    /// Average calendar month — the age is approximate anyway (see `parse`), so a fixed
    /// average avoids pretending to a precision the source text never had.
    private static let month: TimeInterval = 30.44 * day
    private static let year: TimeInterval = 365.25 * day

    /// Renders `date` as an age relative to `now`: minutes up to an hour, then hours up to a
    /// day, then days, weeks, months and years. Returns `nil` for a date in the future.
    static func string(for date: Date, now: Date = Date()) -> String? {
        let elapsed = now.timeIntervalSince(date)
        // Clock skew and our own rounding can put a freshly published video slightly ahead.
        guard elapsed > -minute else { return nil }

        switch elapsed {
        case ..<minute:
            return "Just now"
        case ..<hour:
            return unit(elapsed / minute, "minute")
        case ..<day:
            return unit(elapsed / hour, "hour")
        case ..<week:
            return unit(elapsed / day, "day")
        case ..<month:
            return unit(elapsed / week, "week")
        case ..<year:
            return unit(elapsed / month, "month")
        default:
            return unit(elapsed / year, "year")
        }
    }

    private static func unit(_ value: Double, _ name: String) -> String {
        let count = max(1, Int(value))
        return "\(count) \(name)\(count == 1 ? "" : "s") ago"
    }

    // MARK: - Parsing

    private static let units: [String: TimeInterval] = [
        "second": 1, "minute": minute, "hour": hour,
        "day": day, "week": week, "month": month, "year": year,
    ]

    /// Turns InnerTube's age text into an approximate publish date, or `nil` if the text
    /// carries no age. The result is only as precise as the source: "3 days ago" could be
    /// anything from 72 to 96 hours, so it anchors to the older end of that window.
    ///
    /// Scans for the `<number> <unit> ago` fragment of a subtitle — "12K views • 3 days ago",
    /// "Streamed 2 weeks ago" — rather than assuming the age is the whole string, since the
    /// same line usually carries a view count too.
    static func parse(_ text: String, now: Date = Date()) -> Date? {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)

        // Walk triples so a stray number ("12K views") can't be read as a count.
        for index in words.indices.dropLast(2) where words[index + 2] == "ago" {
            guard let count = Int(words[index]) else { continue }
            // Both "day" and "days" appear, depending on the count.
            let name = words[index + 1].hasSuffix("s") ? String(words[index + 1].dropLast()) : words[index + 1]
            guard let unit = units[name] else { continue }
            return now.addingTimeInterval(-unit * Double(count))
        }
        return nil
    }
}
