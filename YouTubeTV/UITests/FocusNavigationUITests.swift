import XCTest

/// Verifies that the Home feed can be navigated with the Siri Remote's directional
/// pad — the only input tvOS offers, and the thing that is awkward to check by hand.
final class FocusNavigationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()

        // Signed out we get LoginView; a failed load gets the "Try again" error view.
        // Both have a single focusable button, so directional navigation is vacuous —
        // skip rather than report a misleading failure. "Sign out" only exists on the
        // loaded feed, which makes it a reliable marker for "the grid is up".
        app.waitForFocus()
        guard app.buttons["Sign out"].waitForExistence(timeout: 10) else {
            throw XCTSkip(
                "Home feed not loaded (signed out, or Config/Secrets.xcconfig has placeholder "
                    + "credentials) — nothing to navigate. Focus was on: \(app.focusedLabel ?? "nothing")."
            )
        }
    }

    /// A right press should move focus to the next card in the row.
    func testRightPressMovesFocusToNextCard() {
        let before = app.focusedLabel
        XCTAssertNotNil(before, "Expected an element to hold focus on launch.")

        RemoteDriver.press(.right)

        XCTAssertNotEqual(app.focusedLabel, before, "Right press did not move focus.")
    }

    /// Down then up should return focus to where it started, which is the property
    /// that actually breaks when a grid's focus sections are laid out wrong.
    func testDownThenUpRestoresOriginalFocus() {
        let origin = app.focusedLabel

        RemoteDriver.press(.down)
        XCTAssertNotEqual(app.focusedLabel, origin, "Down press did not move focus.")

        RemoteDriver.press(.up)
        XCTAssertEqual(app.focusedLabel, origin, "Focus did not return to the original card.")
    }

    /// Walking right across the row should visit distinct cards rather than getting
    /// stuck — the failure mode when a lazy grid stops materializing focusable views.
    func testWalkingAcrossRowVisitsDistinctCards() {
        var visited: [String] = []
        for _ in 0..<4 {
            if let label = app.focusedLabel { visited.append(label) }
            RemoteDriver.press(.right)
        }

        XCTAssertGreaterThan(
            Set(visited).count, 1,
            "Focus never moved while walking right; visited: \(visited)"
        )
    }
}
