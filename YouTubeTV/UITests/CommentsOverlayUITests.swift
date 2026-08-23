import XCTest

/// Drives the comments panel with a real `.menu` press, which is the only way to exercise the
/// Menu button honestly: the simulator's hardware-keyboard Escape arrives as a keyboard press,
/// not `UIPress.PressType.menu`, so hand-driving it from a shell tests the wrong thing.
final class CommentsOverlayUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()

        guard app.waitForFocus() != nil else {
            throw XCTSkip("Nothing took focus — the app did not reach a usable screen.")
        }
        guard app.buttons["Add profile"].waitForExistence(timeout: 10) else {
            throw XCTSkip("Home feed not loaded (signed out, or placeholder credentials).")
        }
    }

    /// Backing out of a replies list should land on the comment it was opened from, not at the
    /// top of the list.
    func testMenuFromRepliesReturnsFocusToTheParentComment() throws {
        try openComments()

        let entered = try focusOnACommentWithReplies()
        RemoteDriver.press(.select, settle: 1.0)

        guard app.staticTexts["Replies"].waitForExistence(timeout: 10) else {
            throw XCTSkip("Selecting the comment did not open its replies.")
        }

        // Read a couple of replies, as someone actually would.
        RemoteDriver.press(.down, settle: 0.5)
        RemoteDriver.press(.down, settle: 0.5)

        RemoteDriver.press(.menu, settle: 1.5)

        XCTAssertTrue(
            app.staticTexts["Comments"].waitForExistence(timeout: 5),
            "Menu closed the whole panel instead of going back to the top-level list.")

        // Asserted rather than skipped: "nothing is focused" is exactly one of the ways this
        // goes wrong, and a skip would wave it through.
        XCTAssertEqual(
            app.focusedLabel, entered,
            "Focus did not return to the comment the replies were opened from.")
    }

    /// Menu at the top level still takes the whole panel down — the level-aware handling must
    /// not have cost the plain close.
    func testMenuFromTheTopLevelClosesThePanel() throws {
        try openComments()

        RemoteDriver.press(.menu, settle: 1.5)

        let comments = app.staticTexts["Comments"]
        XCTAssertFalse(
            comments.exists && comments.isHittable,
            "Menu at the top level left the comments panel up.")
    }

    // MARK: - Helpers

    /// How far down the list the comment to open has to be. Any row but the first would do to
    /// tell "focus was restored" from "the list reset to the top" apart, but a few rows down
    /// also means the list had to scroll to show it, which is the half that actually broke.
    ///
    /// Kept small because reply threads cluster in a video's top comments: demanding a deep one
    /// only makes this skip on videos whose replies are all near the top.
    private static let minimumReplyDepth = 3

    /// How many times to try bringing the panel up, each try covering one rung of the stream
    /// ladder. Enough for every client `StreamService` falls back through.
    private static let panelAttempts = 4

    /// How many rows to walk looking for one. Which comments have replies is up to YouTube, so
    /// this hunts rather than assuming a position.
    private static let replySearchDepth = 40

    /// Moves focus down to a comment that is both deep enough and has replies to open, and
    /// returns its label — long, but unique, which is all this needs it to be.
    ///
    /// A row's accessibility label is its author, text, likes and then its reply count, so a
    /// trailing "replies" is the reliable marker; `contains` would also match a comment that
    /// merely talks about replies. Case-insensitively, because a thread whose count YouTube
    /// omitted is labelled "Replies" rather than "N replies".
    private func focusOnACommentWithReplies() throws -> String {
        var previous: String?
        for depth in 1...Self.replySearchDepth {
            RemoteDriver.press(.down, settle: 0.5)
            let label = app.focusedLabel
            // The bottom of the loaded page: presses stop moving focus, so give up here rather
            // than spend the rest of the budget pressing into it.
            if label == previous { break }
            previous = label
            if depth >= Self.minimumReplyDepth, let label, label.lowercased().hasSuffix("replies") {
                return label
            }
        }
        throw XCTSkip("No comment with replies far enough down this video's first page.")
    }

    /// A search whose top result is reliably a big channel's video, and so has enough comments
    /// to contain reply threads.
    ///
    /// Searched for rather than taken off the Home feed: what the feed puts first is whatever
    /// was uploaded most recently, which is regularly a minutes-old video with a single comment
    /// and nothing to open.
    private static let videoQuery = "TLDR News"

    /// Plays a comment-heavy video and brings up the comments panel over it.
    private func openComments() throws {
        try playFirstSearchResult()

        // There is no queryable marker for "the stream is playing", and the transport bar can't
        // be reached before there is one. Retried rather than waited out once: PlayerView's
        // ladder allows 15s per client and can work through several, so a single fixed wait
        // would press into the loading overlay and give up on a video that was merely slow.
        let panel = app.staticTexts["Comments"]
        for _ in 0..<Self.panelAttempts where !panel.exists {
            Thread.sleep(forTimeInterval: 10)
            // The transport bar first, then up onto its row of buttons, where "Comments" sits.
            RemoteDriver.press(.down, settle: 1.0)
            RemoteDriver.press(.up, settle: 1.0)
            RemoteDriver.press(.select, settle: 1.5)
            _ = panel.waitForExistence(timeout: 8)
        }
        guard panel.exists else {
            throw XCTSkip("The comments panel did not come up — no stream, or no comments.")
        }
        // The first page has to be on screen before anything can be focused in it.
        Thread.sleep(forTimeInterval: 2)
    }

    /// Searches for `videoQuery` and starts playing the first result.
    private func playFirstSearchResult() throws {
        let search = app.buttons["Search"]
        // Focus starts on the first card of the top row; up lands in the header, where Search is
        // the leftmost control. Which control takes focus first is up to the focus engine's
        // memory, so walk left rather than assume.
        RemoteDriver.press(.up)
        for _ in 0..<6 where !search.hasFocus {
            RemoteDriver.press(.left)
        }
        guard search.hasFocus else {
            throw XCTSkip("Could not reach the search icon; focus is on: \(app.focusedLabel ?? "nothing").")
        }
        RemoteDriver.press(.select)
        app.typeText(Self.videoQuery)

        let cards = app.buttons.matching(identifier: "SearchResult")
        try XCTSkipUnless(
            cards.element(boundBy: 0).waitForExistence(timeout: 30),
            "No results for “\(Self.videoQuery)”, so there is nothing to play.")

        // Focus is in the search field, with the on-screen keyboard between it and the grid, so
        // "down" has to be repeated until it lands on a result rather than assumed to reach one.
        var card: XCUIElement?
        for _ in 0..<4 where card == nil {
            RemoteDriver.press(.down)
            card = cards.allElementsBoundByIndex.first { $0.hasFocus }
        }
        guard card != nil else {
            throw XCTSkip("Focus never reached a result card; it is on: \(app.focusedLabel ?? "nothing").")
        }
        RemoteDriver.press(.select, settle: 1.0)
    }
}
