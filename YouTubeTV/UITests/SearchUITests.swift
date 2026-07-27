import XCTest

/// Drives the search flow the way a user does — remote presses to the icon, then typing
/// into the tvOS keyboard — because nothing about it can be checked from the outside:
/// the request shape, the response parsing and the focus path only meet at runtime.
final class SearchUITests: XCTestCase {
    private var app: XCUIApplication!

    /// The word typed into the field. Deliberately generic so it keeps matching as
    /// YouTube's index changes; the assertion is "results came back", not which ones.
    private static let query = "swift programming"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()

        // Same rationale as FocusNavigationUITests: signed out, or a feed that failed to
        // load, leaves no search icon to reach — skip rather than fail on a missing screen.
        guard app.waitForFocus() != nil, app.buttons["Search"].waitForExistence(timeout: 15) else {
            throw XCTSkip(
                "Home feed not loaded (signed out, or Config/Secrets.xcconfig has placeholder "
                    + "credentials) — the search icon is never reached."
            )
        }
    }

    /// Typing a query should replace the prompt with a grid of playable results.
    func testSearchingShowsResults() throws {
        try openSearch()

        // The search field takes focus when the screen appears, so this goes straight in.
        app.typeText(Self.query)

        // Result cards carry their own identifier — the tvOS keyboard is built from
        // buttons, so counting plain buttons would pass with zero results.
        let cards = app.buttons.matching(identifier: "SearchResult")

        // The first card appearing ends the wait: this is a debounce plus a network
        // round-trip, not a render.
        XCTAssertTrue(
            cards.element(boundBy: 0).waitForExistence(timeout: 30),
            "No results for “\(Self.query)” — focus is on: \(app.focusedLabel ?? "nothing")."
        )

        // A single card would also be produced by a response the parser only half
        // understood; a real result page fills the grid.
        XCTAssertGreaterThan(cards.count, 4, "Only \(cards.count) result(s) parsed out of the response.")

        // Every card must be able to open the player, which needs a title to show and
        // an id behind it — an unlabelled card means the cell parsed but its metadata
        // didn't, which is exactly the failure a changed renderer shape produces.
        let unlabelled = cards.allElementsBoundByIndex.filter { $0.label.isEmpty }
        XCTAssertTrue(unlabelled.isEmpty, "\(unlabelled.count) result card(s) parsed without a title.")

        // Attached even on success: the parser depends on YouTube's response shape, so
        // when this test starts failing the picture of what came back is the evidence.
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Search results"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// A result must reach the player, which is the wiring most likely to be wrong:
    /// the player is presented over the navigation stack Search was pushed onto.
    func testSelectingAResultOpensThePlayer() throws {
        try openSearch()
        app.typeText(Self.query)

        let cards = app.buttons.matching(identifier: "SearchResult")
        try XCTSkipUnless(
            cards.element(boundBy: 0).waitForExistence(timeout: 30),
            "No results came back, so there is nothing to select."
        )

        // Focus is in the search field, with the on-screen keyboard between it and the
        // grid — so "down" has to be repeated until it lands on an actual result rather
        // than assumed to reach one, or select would just type another letter.
        var focusedCard: XCUIElement?
        for _ in 0..<4 where focusedCard == nil {
            RemoteDriver.press(.down)
            focusedCard = cards.allElementsBoundByIndex.first { $0.hasFocus }
        }
        let card = try XCTUnwrap(
            focusedCard, "Focus never reached a result card; it is on: \(app.focusedLabel ?? "nothing").")

        RemoteDriver.press(.select)

        // Focus leaving the grid is the signal that the player took over. The cards
        // themselves stay queryable — a `fullScreenCover` leaves the view it covers in
        // the accessibility tree — so their existence proves nothing either way. Focus
        // does move, and it moves without waiting on a stream to resolve, which keeps
        // this a presentation test rather than a playback one.
        let deadline = Date().addingTimeInterval(15)
        while card.hasFocus && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertFalse(
            card.hasFocus,
            "Focus is still on “\(card.label)”, so selecting it never presented the player."
        )

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Player presented from search"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Moves focus to the search icon and opens it.
    private func openSearch() throws {
        let search = app.buttons["Search"]

        // Focus starts on the first card of the top row; up lands in the header. Search
        // is the leftmost control there, with the profile avatars and the plus to its
        // right, so walking left reaches it — but which control takes focus first depends
        // on the focus engine's memory, so nudge rather than assume. The bound covers a
        // header with several profiles signed in.
        RemoteDriver.press(.up)
        for _ in 0..<6 where !search.hasFocus {
            RemoteDriver.press(.left)
        }

        guard search.hasFocus else {
            throw XCTSkip("Could not move focus to the search icon; focus is on: \(app.focusedLabel ?? "nothing").")
        }

        RemoteDriver.press(.select)
    }
}
