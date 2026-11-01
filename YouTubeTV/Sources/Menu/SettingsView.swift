import SwiftUI

/// The Settings screen: a stack of labelled rows, each with a switch on the right.
struct SettingsView: View {
    /// Bumped by the shell when the menu picks Settings. The first row takes focus, which is
    /// what closes the menu behind it — see `SideMenu.onSelect`.
    var focusRequest: Int = 0

    @AppStorage(AmbientBackgroundSetting.key)
    private var isAmbientBackgroundOn = AmbientBackgroundSetting.defaultValue

    @FocusState private var isFirstRowFocused: Bool

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                Text(MenuSection.settings.title)
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(.white)

                VStack(spacing: 20) {
                    SettingsToggleRow(
                        title: "Ambient background",
                        detail: "Home's background takes its colours from the focused video's channel.",
                        isOn: $isAmbientBackgroundOn
                    )
                    .focused($isFirstRowFocused)
                }
                .frame(maxWidth: 1100, alignment: .leading)
                .padding(.top, 56)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.horizontalInset)
            .padding(.vertical, 80)
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
            isFirstRowFocused = true
        }
    }
}

/// One setting: its name and a line on what it does, and a switch that flips on Select.
private struct SettingsToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            SettingsRowLabel(title: title, detail: detail, isOn: isOn)
        }
        .buttonStyle(SettingsRowStyle())
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// Drawn the way a focused card is — a light panel with dark text — so the one focus look holds
/// across the app.
private struct SettingsRowLabel: View {
    let title: String
    let detail: String
    let isOn: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 32) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 30, weight: .semibold))
                Text(detail)
                    .font(.system(size: 22, weight: .medium))
                    .opacity(0.6)
            }
            Spacer()
            toggle
        }
        .foregroundStyle(isFocused ? Color.black : Color.white)
        .padding(.horizontal, 36)
        .padding(.vertical, 28)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isFocused ? Color(white: 0.86) : Color.white.opacity(0.05))
        }
        .scaleEffect(isFocused ? 1.02 : 1)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }

    private var toggle: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Color.green : Color.gray.opacity(0.5))
            Circle()
                .fill(.white)
                .padding(4)
        }
        .frame(width: 96, height: 50)
        .animation(.easeInOut(duration: 0.2), value: isOn)
        .accessibilityHidden(true)
    }
}

/// No system chrome: the label draws its own focus state.
private struct SettingsRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
