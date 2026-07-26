import XCTest

/// Helpers for driving the tvOS focus engine from a UI test.
///
/// tvOS has no touch input, so navigation happens exclusively through `XCUIRemote`
/// presses. These wrappers add the waiting and focus lookups that every test needs.
enum RemoteDriver {
    /// Presses a remote button and gives the focus engine time to settle.
    ///
    /// SwiftUI focus changes are animated (`HomeView` uses a 0.15s ease), so reading
    /// focus immediately after a press can observe the pre-press state.
    static func press(_ button: XCUIRemote.Button, settle: TimeInterval = 0.4) {
        XCUIRemote.shared.press(button)
        Thread.sleep(forTimeInterval: settle)
    }
}

extension XCUIApplication {
    /// The currently focused element, if any.
    ///
    /// tvOS focus can land on a button (a video card, "Sign out") or another focusable
    /// view, so this searches all descendants rather than a single element type.
    var focusedElement: XCUIElement? {
        descendants(matching: .any)
            .allElementsBoundByIndex
            .first { $0.exists && $0.hasFocus }
    }

    /// Label of the focused element — the cheapest stable way to tell whether a
    /// remote press actually moved focus.
    var focusedLabel: String? {
        focusedElement?.label
    }

    /// Waits until some element holds focus, which also serves as a readiness check:
    /// the feed grid only takes focus once the first page of videos has loaded.
    ///
    /// Returns that element's label, which may be the empty string — not every
    /// focusable view carries one, and an unlabelled element still counts as focus.
    /// Returns nil only if nothing took focus before the timeout.
    func waitForFocus(timeout: TimeInterval = 30) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let element = focusedElement { return element.label }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return nil
    }
}
