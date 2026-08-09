import SwiftUI

/// The screen behind a menu item that hasn't been built yet — Settings, now the only one.
/// (Subscriptions and History are real: see `SubscriptionsView` and `HistoryView`.)
///
/// Deliberately not a blank page: it lays out the shape its real content will take, in empty
/// outlines. That way the prototype can be judged on the thing being prototyped (does navigating
/// left to the menu and picking a screen feel right?) without inventing settings to fill it with,
/// which would be worse than showing nothing — a page of made-up data is indistinguishable from a
/// page that works.
struct MenuPlaceholderPage: View {
    let section: MenuSection

    /// Bumped by the shell when the menu picks a section. The page takes focus, which is what
    /// closes the menu behind it — see `SideMenu.onSelect`.
    var focusRequest: Int = 0

    /// The page as a whole is the focus target. There is nothing on it to act on yet, so this
    /// is somewhere for focus to *be* while the menu is shut; pressing left hands it back.
    @FocusState private var isFocused: Bool

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                Text(section.title)
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(.white)

                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 12)

                skeleton
                    .padding(.top, 56)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.horizontalInset)
            .padding(.vertical, 80)
            // Inside the scroll view rather than on it: a focusable scroll view swallows the
            // left press for its own scrolling, and left is how you get back to the menu.
            .focusable()
            .focused($isFocused)
        }
        // The page is one focus region and the menu is another. Without this the page — which
        // runs the full height of the screen, starting above the menu's first row — is a
        // candidate for an *upward* move out of the menu, so stepping up from a row lands on
        // the page instead of on the row above.
        .focusSection()
        // The same delay the feed's handoffs need: the page has to be on screen before there
        // is anything to put focus on.
        .task(id: focusRequest) {
            guard focusRequest > 0 else { return }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            isFocused = true
        }
    }

    private var subtitle: String {
        switch section {
        // None of the three reaches this page — Home is the feed, and Subscriptions and History
        // are their own screens — but the switch has to be total, and an empty subtitle is the
        // honest answer for a section that never gets here.
        case .home, .subscriptions, .history:
            return ""
        case .settings:
            return "Playback, profiles and what shows on Home. Not wired up yet."
        }
    }

    @ViewBuilder
    private var skeleton: some View {
        switch section {
        case .home, .subscriptions, .history:
            EmptyView()
        case .settings:
            settingsList
        }
    }

    /// What Settings will be: a stack of labelled rows, each with a control on the right.
    private var settingsList: some View {
        VStack(spacing: 20) {
            ForEach(0..<5, id: \.self) { _ in
                HStack {
                    outline(width: 320, height: 18)
                    Spacer()
                    Capsule()
                        .strokeBorder(.white.opacity(0.22), lineWidth: 2)
                        .frame(width: 96, height: 44)
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 28)
                .background {
                    RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.05))
                }
            }
        }
        .frame(maxWidth: 1100, alignment: .leading)
    }

    /// A stand-in for a line of text. Filled rather than stroked, unlike the frames above, so
    /// it reads as a word that isn't there yet rather than an empty box.
    private func outline(width: CGFloat, height: CGFloat) -> some View {
        Capsule()
            .fill(.white.opacity(0.16))
            .frame(width: width, height: height)
    }
}
