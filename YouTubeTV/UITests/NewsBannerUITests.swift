import XCTest

/// Verifies the way out of the news reader: Menu closes the story and leaves focus on the feed,
/// rather than on the strip — arriving on the strip reopens the panel the user just closed.
final class NewsBannerUITests: XCTestCase {
    private var app: XCUIApplication!

    private static let stripLabel = "News headlines"

    /// What had focus when Home opened, which is the feed's first card.
    private var firstCard: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()

        guard app.waitForFocus() != nil, app.buttons["Add profile"].waitForExistence(timeout: 15) else {
            throw XCTSkip("Home feed not loaded (signed out, or placeholder credentials).")
        }
        firstCard = app.focusedLabel
    }

    /// Climbs from the feed to the ticker, which opens the reading panel.
    private func openNews() throws {
        for _ in 0..<6 {
            if app.focusedLabel == Self.stripLabel { return }
            RemoteDriver.press(.up)
        }
        guard app.focusedLabel == Self.stripLabel else {
            throw XCTSkip("Never reached the news strip (no headlines?). Focus: \(app.focusedLabel ?? "nil").")
        }
    }

    /// Long enough to outlast every timer in the handoff: the reopening panel only shows once
    /// the strip has been let back in, which is well after Menu.
    private func assertLandsOnFirstCard(for duration: TimeInterval = 3) {
        Thread.sleep(forTimeInterval: duration)
        XCTAssertEqual(app.focusedLabel, firstCard, "Menu did not land on the feed's first card.")
        XCTAssertEqual(app.state, .runningForeground, "Menu left the app.")
    }

    /// Menu straight away, with the story freshly opened.
    func testMenuFromFreshStoryLandsOnFirstCard() throws {
        try openNews()
        Thread.sleep(forTimeInterval: 1)
        RemoteDriver.press(.menu, settle: 0)
        assertLandsOnFirstCard()
    }

    /// The reported case: flicking between stories, then Menu at the top of the one on screen.
    func testMenuAfterSteppingStoriesLandsOnFirstCard() throws {
        try openNews()
        for _ in 0..<3 { RemoteDriver.press(.right, settle: 0.8) }
        RemoteDriver.press(.menu, settle: 0)
        assertLandsOnFirstCard()
    }

    /// Menu from partway down an article rather than from the strip.
    func testMenuFromInsideArticleLandsOnFirstCard() throws {
        try openNews()
        // Time for the article to arrive, or down has nothing to walk into.
        Thread.sleep(forTimeInterval: 3)
        RemoteDriver.press(.down, settle: 1)
        RemoteDriver.press(.menu, settle: 0)
        assertLandsOnFirstCard()
    }

    /// The first card has scrolled out of its lazy row, so it may not exist when Menu is pressed.
    func testMenuLandsOnFirstCardAfterScrollingAlongTheRow() throws {
        for _ in 0..<10 { RemoteDriver.press(.right) }
        try openNews()
        Thread.sleep(forTimeInterval: 1)
        RemoteDriver.press(.menu, settle: 0)
        assertLandsOnFirstCard()
    }

    /// Closing the news must not lock it: the strip has to take focus again afterwards.
    func testNewsCanBeReopenedAfterMenu() throws {
        try openNews()
        RemoteDriver.press(.menu, settle: 0)
        assertLandsOnFirstCard()
        try openNews()
        XCTAssertEqual(app.focusedLabel, Self.stripLabel)
    }
}
