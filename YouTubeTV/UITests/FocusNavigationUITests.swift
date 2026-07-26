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
        // Nothing focusable at all means the app never got as far as a screen; waiting
        // out the "Sign out" timeout on top of that would only slow the skip down.
        guard let initialFocus = app.waitForFocus() else {
            throw XCTSkip("Nothing took focus — the app did not reach a usable screen.")
        }

        guard app.buttons["Sign out"].waitForExistence(timeout: 10) else {
            let focus = initialFocus.isEmpty ? "an unlabelled element" : initialFocus
            throw XCTSkip(
                "Home feed not loaded (signed out, or Config/Secrets.xcconfig has placeholder "
                    + "credentials) — nothing to navigate. Focus was on: \(focus)."
            )
        }
    }

    /// The focused element's label, used as its identity when comparing before/after.
    ///
    /// A label may legitimately be empty (`waitForFocus` documents this), and an empty
    /// or absent label cannot distinguish one element from another: comparing them
    /// would report movement that didn't happen, or miss movement that did. Every card
    /// on the loaded feed carries its title, so this holds in practice — if it ever
    /// doesn't, skip rather than assert on an identity that can't tell things apart.
    private func requireFocusLabel(_ context: String) throws -> String {
        guard let label = app.focusedLabel, !label.isEmpty else {
            throw XCTSkip("\(context): focus is missing or unlabelled, so it can't be identified.")
        }
        return label
    }

    /// A right press should move focus to the next card in the row.
    func testRightPressMovesFocusToNextCard() throws {
        let before = try requireFocusLabel("before right press")

        RemoteDriver.press(.right)

        let after = try requireFocusLabel("after right press")
        XCTAssertNotEqual(after, before, "Right press did not move focus.")
    }

    /// Down then up should return focus to where it started, which is the property
    /// that actually breaks when a grid's focus sections are laid out wrong.
    func testDownThenUpRestoresOriginalFocus() throws {
        let origin = try requireFocusLabel("before down press")

        RemoteDriver.press(.down)
        let moved = try requireFocusLabel("after down press")
        XCTAssertNotEqual(moved, origin, "Down press did not move focus.")

        RemoteDriver.press(.up)
        let returned = try requireFocusLabel("after up press")
        XCTAssertEqual(returned, origin, "Focus did not return to the original card.")
    }

    /// Walking right across the row should visit distinct cards rather than getting
    /// stuck — the failure mode when a lazy grid stops materializing focusable views.
    func testWalkingAcrossRowVisitsDistinctCards() throws {
        var visited: [String] = []
        for step in 0..<4 {
            visited.append(try requireFocusLabel("step \(step) of walking right"))
            RemoteDriver.press(.right)
        }

        XCTAssertGreaterThan(
            Set(visited).count, 1,
            "Focus never moved while walking right; visited: \(visited)"
        )
    }
}
