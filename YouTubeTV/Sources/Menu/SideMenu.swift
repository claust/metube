import SwiftUI

/// The screens the left-hand menu switches between. Home is the feed the app has always
/// opened on; the other three are prototypes — see `MenuPlaceholderPage`.
enum MenuSection: String, CaseIterable, Identifiable {
    case home
    case subscriptions
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .subscriptions: return "Subscriptions"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    /// The glyph shown on the collapsed rail, which is all the menu is most of the time — so
    /// each one has to read as its screen on its own.
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .subscriptions: return "rectangle.stack.badge.play.fill"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape.fill"
        }
    }
}

/// The menu down the left edge: a narrow rail of glyphs that widens into labelled rows when
/// focus reaches it.
///
/// It is always in the view tree rather than being summoned by a press, because that is what
/// makes "navigate left off the first card" find it: the focus engine only moves to something
/// that is already there. The rail is the width the shell reserves, and the expanded panel is
/// drawn *over* the screen behind it — widening the layout instead would shove every row
/// sideways the moment focus arrived here.
struct SideMenu: View {
    /// The section on screen. The menu writes it on a press; the shell reads it to decide what
    /// to draw beside the rail.
    @Binding var section: MenuSection

    /// Whether the menu is available at all. False while the feed is still loading: nothing
    /// on that screen can hold focus yet, so a menu that could would be handed the app on
    /// launch — and open itself over an empty screen the user hasn't seen.
    var canTakeFocus: Bool = true

    /// Reports whether the menu holds focus, so the shell can dim what's behind it.
    var onExpandedChange: (Bool) -> Void = { _ in }

    /// Fired on every press, including one that picks the section already showing. The shell
    /// answers it by taking focus into that section, which is what shuts the menu — a menu
    /// left open over the screen it just opened would be a menu you have to dismiss.
    var onSelect: () -> Void = {}

    /// What the shell reserves for the menu, and the width of the collapsed rail.
    static let railWidth: CGFloat = 100
    /// The panel's width once focus arrives. Wide enough for the longest label at a size that
    /// is legible from a sofa.
    static let expandedWidth: CGFloat = 420
    /// Big enough that the two runes are legible from a sofa without the header competing
    /// with the rows under it.
    private static let markHeight: CGFloat = 64

    /// Which row has focus, and `nil` when focus is anywhere else on screen — which is also
    /// how the menu knows to collapse.
    @FocusState private var focusedItem: MenuSection?

    /// True while the menu does not hold focus — so the next row to take it is one the user
    /// has just arrived on from the screen beside it, rather than one they stepped onto from
    /// the row above. See the snap below.
    @State private var isEntering = true

    /// Whether the panel is open. Follows the focus, but not instantly — see the debounce
    /// below, which is what keeps a step from one row to the next from shutting the menu.
    @State private var isOpen = false

    private var isExpanded: Bool { isOpen }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            wordmark

            ForEach(MenuSection.allCases) { item in
                Button {
                    section = item
                    // Let go of focus as part of the press. The screen being opened claims it
                    // a beat later (see `onSelect`), but it cannot take it off a menu that is
                    // still holding on — and this is also what shuts the panel.
                    focusedItem = nil
                    onSelect()
                } label: {
                    MenuRow(
                        item: item,
                        isSelected: section == item,
                        isFocused: focusedItem == item,
                        isExpanded: isExpanded
                    )
                }
                // The row draws its own focus — the white capsule. Every stock button style
                // adds a highlight of its own behind that, which reads as a second, greyer
                // selection around the first, so this style draws the label and nothing else.
                .buttonStyle(FlatButtonStyle())
                .focused($focusedItem, equals: item)
                .accessibilityLabel(item.title)
            }

            Spacer()
        }
        .disabled(!canTakeFocus)
        .padding(.top, 56)
        .frame(width: isExpanded ? Self.expandedWidth : Self.railWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(alignment: .leading) { backdrop }
        // Up/down belongs to the menu once focus is in it, rather than being read as a move
        // towards whatever row of the feed happens to be level with it.
        //
        // Applied here, *above* the frame below, on purpose: that frame hands the layout only
        // the rail, so a section declared under it would be a 100pt-wide region containing
        // rows drawn 400pt wide — and a step up from one row would look, to the focus engine,
        // like a move out of the region rather than to the row above.
        .focusSection()
        // Only the rail is claimed from the layout; everything wider than it hangs over the
        // screen to the right, which is the whole point of the panel.
        .frame(width: Self.railWidth, alignment: .leading)
        .animation(.easeOut(duration: 0.22), value: isExpanded)
        .task(id: focusedItem) {
            guard let item = focusedItem else {
                // Not necessarily gone: tvOS drops focus for an instant on its way from one
                // row to the next, and closing on that would re-lay the rows out underneath
                // the move — which loses it, and drops focus out of the menu altogether. The
                // task id cancels this the moment focus lands somewhere, so only a move that
                // really did leave gets through.
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled, focusedItem == nil else { return }
                isOpen = false
                isEntering = true
                onExpandedChange(false)
                return
            }
            // Arriving from the feed, focus lands on whichever row happens to be level with
            // the card it came off — which is rarely the section you are on. Opening a menu
            // should start you where you are, so the first row to take it hands focus straight
            // to the current section. Only on the way in: stepping between rows inside the
            // menu is exactly what this must not interfere with.
            if isEntering {
                isEntering = false
                if item != section { focusedItem = section }
            }
            isOpen = true
            onExpandedChange(true)
        }
    }

    /// Sits above the rows so the open panel has a head rather than starting mid-air: the
    /// app's own mark, from the same artwork as the icon on the tvOS home screen — see
    /// `Scripts/generate-app-icon.py`. The mark alone, with no name beside it; the runes are
    /// the app, and spelling that out under its own menu adds nothing.
    ///
    /// Its space is held whether or not it is drawn, so opening the menu doesn't shunt the
    /// rows down past the one focus has just landed on.
    private var wordmark: some View {
        HStack {
            if isExpanded {
                Image("App Mark")
                    .resizable()
                    .scaledToFit()
                    .frame(height: Self.markHeight)
                    .transition(.opacity)
            }
        }
        .frame(height: Self.markHeight, alignment: .leading)
        .padding(.horizontal, MenuRow.horizontalPadding)
        .padding(.bottom, 36)
    }

    /// A gradient rather than a panel edge: a hard border across the feed would read as a
    /// second screen, where a wash the rows fade into reads as the menu being *over* them.
    /// Runs past the panel so the fade finishes in open space instead of at the last label.
    @ViewBuilder
    private var backdrop: some View {
        LinearGradient(
            colors: [.black, .black.opacity(0.92), .black.opacity(0)],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: isExpanded ? Self.expandedWidth + 220 : Self.railWidth)
        .opacity(isExpanded ? 1 : 0)
        .ignoresSafeArea()
    }
}

/// Draws the label and nothing else — no focus highlight, no pressed state. The rows handle
/// both themselves.
private struct FlatButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// One row of the menu. Focused it is a filled capsule — the tvOS convention, and the only
/// state that has to be readable at a glance. Selected-but-not-focused is quieter: the label
/// stays white where the others dim, so leaving the menu still shows which screen you're on.
private struct MenuRow: View {
    let item: MenuSection
    let isSelected: Bool
    let isFocused: Bool
    let isExpanded: Bool

    /// A fixed box for the glyph, so the labels line up under each other however wide the
    /// symbols happen to draw — and so the icons don't shift when the panel opens.
    static let glyphWidth: CGFloat = 44
    static let horizontalPadding: CGFloat = 24
    /// Fixed, so the rows sit in the same places open or shut — the focus that opened the
    /// menu would otherwise land on one row and end up beside another.
    static let rowHeight: CGFloat = 72
    /// How much narrower than the open panel a row is, so the focused capsule stops short of
    /// the panel's edge instead of running into the screen behind it.
    static let panelInset: CGFloat = 44

    var body: some View {
        HStack(spacing: 20) {
            // Collapsed, the row is an empty box: the menu isn't on screen until you go
            // looking for it. It still has to be a *drawn* box rather than a hidden one —
            // tvOS won't move focus onto a view it considers invisible, and this is what the
            // left press off the first card lands on.
            if isExpanded {
                Image(systemName: item.icon)
                    .font(.system(size: 28, weight: .semibold))
                    .frame(width: Self.glyphWidth)
                Text(item.title)
                    .font(.system(size: 28, weight: .semibold))
                    .fixedSize()
                    .transition(.opacity)
            }
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, Self.horizontalPadding)
        .frame(
            width: isExpanded ? SideMenu.expandedWidth - Self.panelInset : SideMenu.railWidth,
            height: Self.rowHeight,
            alignment: .leading
        )
        .background {
            Capsule().fill(background)
        }
        // No scale on focus: it would make the focused capsule a few points longer than the
        // one marking the section you're on, and two bars of different lengths in the same
        // column read as a mistake rather than as two different states.
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }

    private var foreground: Color {
        if isFocused { return .black }
        return isSelected ? .white : .white.opacity(0.55)
    }

    private var background: Color {
        guard isExpanded else { return .clear }
        if isFocused { return .white }
        return isSelected ? .white.opacity(0.14) : .clear
    }
}
