import SwiftUI

/// The signed-in accounts, as a row of avatars in the Home header, plus a button to add one.
///
/// Pressing an avatar opens a short menu rather than switching straight away: an avatar is a
/// small target on a screen driven by a d-pad, and "switch account" and "sign out" are both
/// things you'd rather confirm than trigger by overshooting.
struct ProfileBar: View {
    /// Called when the user picks the plus button. The orchestrator wires this to the sign-in
    /// screen — `ProfileBar` has no way to present one from inside the header.
    var onAddProfile: () -> Void

    @EnvironmentObject private var authStore: AuthStore

    /// The profile whose menu is open, and `nil` when none is.
    @State private var menuProfile: Profile?

    var body: some View {
        HStack(spacing: 16) {
            ForEach(authStore.profiles) { profile in
                ProfileAvatarButton(
                    profile: profile,
                    isActive: profile.id == authStore.activeProfileID,
                    action: { menuProfile = profile }
                )
            }

            AddProfileButton(action: onAddProfile)
        }
        .confirmationDialog(
            menuProfile?.name ?? "",
            isPresented: Binding(
                get: { menuProfile != nil },
                set: { isPresented in
                    if !isPresented { menuProfile = nil }
                }
            ),
            titleVisibility: .visible,
            presenting: menuProfile
        ) { profile in
            // Switching to the profile you are already on isn't an action, so the active
            // profile's menu is just the sign-out.
            if profile.id != authStore.activeProfileID {
                Button("Use this profile") { authStore.activate(profile.id) }
            }
            Button("Sign out", role: .destructive) { authStore.signOut(profile.id) }
        }
    }
}

/// One account's avatar. The active one is ringed and full strength; the others are dimmed,
/// so which account the feed belongs to is legible from across the room.
private struct ProfileAvatarButton: View {
    let profile: Profile
    let isActive: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    private static let size: CGFloat = 64

    var body: some View {
        Button(action: action) {
            avatar
                .frame(width: Self.size, height: Self.size)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .strokeBorder(.white, lineWidth: isActive ? 4 : 0)
                }
                .opacity(isActive || isFocused ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.15 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
        // The avatar carries no text of its own, so name it for VoiceOver and the UI tests.
        // The state is part of the label because the ring that conveys it is purely visual.
        .accessibilityLabel(isActive ? "\(profile.name), current profile" : profile.name)
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = profile.avatarURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    // Covers the load as well as a failure: a spinner this small reads as a
                    // glitch, and the initial is what the avatar falls back to permanently.
                    initialAvatar
                }
            }
        } else {
            initialAvatar
        }
    }

    /// The account's first letter on a flat disc — YouTube's own stand-in for an account
    /// without a picture, and what a profile shows until its details have been fetched.
    private var initialAvatar: some View {
        Circle()
            .fill(Color(white: 0.3))
            .overlay {
                Text(profile.initial)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

/// Adds another account. A dashed outline rather than a filled disc, so it doesn't read as a
/// profile that happens to have no picture yet.
private struct AddProfileButton: View {
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Circle()
                .strokeBorder(.white.opacity(isFocused ? 1 : 0.5), style: StrokeStyle(lineWidth: 3, dash: [6, 6]))
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white.opacity(isFocused ? 1 : 0.6))
                }
                .frame(width: 64, height: 64)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.15 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
        .accessibilityLabel("Add profile")
    }
}
