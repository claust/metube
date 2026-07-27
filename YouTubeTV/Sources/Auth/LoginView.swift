import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// TV-sized sign-in screen driving the OAuth device-activation flow.
///
/// On appear it requests a user code, shows the activation instructions + code + a
/// scannable QR code, and simultaneously polls for the token. On success it hands the
/// tokens to `AuthStore`; `RootView` observes `isLoggedIn` and swaps to the feed.
///
/// The same screen adds a further profile to an already signed-in TV. In that case it is
/// presented over the feed and `onDismiss` takes it away again — on success as well as when the
/// user backs out, since the feed behind it is still perfectly usable.
struct LoginView: View {
    /// Set only when this screen is presented over the feed. `nil` for the first sign-in, where
    /// there is nothing to go back to.
    var onDismiss: (() -> Void)?

    @EnvironmentObject private var authStore: AuthStore

    /// UI phases for the flow.
    private enum Phase {
        case requesting
        case waiting(DeviceAuthService.DeviceCode)
        case failed(String)
    }

    @State private var phase: Phase = .requesting
    @State private var flowTask: Task<Void, Never>?

    private let service = DeviceAuthService()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch phase {
            case .requesting:
                requestingView
            case .waiting(let code):
                waitingView(code)
            case .failed(let message):
                failedView(message)
            }
        }
        .foregroundStyle(.white)
        .onAppear { startFlow() }
        .onDisappear { flowTask?.cancel() }
        // The Menu button is how a tvOS user backs out of anything; without this it does
        // nothing at all on a cover, leaving the only way out a completed sign-in.
        .onExitCommand(perform: onDismiss)
    }

    /// Escape hatch while adding a profile. Absent on the first sign-in, where cancelling
    /// would leave an empty screen.
    @ViewBuilder
    private var cancelButton: some View {
        if let onDismiss {
            Button("Cancel", action: onDismiss)
                .font(.system(size: 30, weight: .semibold))
        }
    }

    // MARK: - Phase views

    private var requestingView: some View {
        VStack(spacing: 32) {
            ProgressView()
                .scaleEffect(2.0)
            Text("Preparing sign-in…")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }

    private func waitingView(_ code: DeviceAuthService.DeviceCode) -> some View {
        HStack(alignment: .center, spacing: 100) {
            // Left: instructions + code.
            VStack(alignment: .leading, spacing: 48) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Sign in to YouTube")
                        .font(.system(size: 64, weight: .bold))
                    Text("On your phone or computer, go to")
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(.secondary)
                    Text(displayURL(code.verificationURL))
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(.red)
                }

                VStack(alignment: .leading, spacing: 16) {
                    Text("and enter this code:")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text(spacedCode(code.userCode))
                        .font(.system(size: 96, weight: .bold, design: .monospaced))
                        .kerning(8)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }

                HStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.4)
                    Text("Waiting for you to sign in…")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                }

                cancelButton
            }

            // Right: scannable QR code (nice-to-have).
            if let qr = qrImage(for: activationURL(code)) {
                VStack(spacing: 20) {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 340, height: 340)
                        .background(Color.white)
                        .cornerRadius(16)
                    Text("Scan to sign in")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(80)
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 40) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.yellow)
            Text("Something went wrong")
                .font(.system(size: 48, weight: .bold))
            Text(message)
                .font(.title2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
            HStack(spacing: 32) {
                Button(action: startFlow) {
                    Text("Try again")
                        .font(.system(size: 34, weight: .semibold))
                        .padding(.horizontal, 20)
                }
                .focusable()

                cancelButton
            }
        }
        .padding(80)
    }

    // MARK: - Flow control

    @MainActor
    private func startFlow() {
        flowTask?.cancel()
        phase = .requesting

        flowTask = Task {
            do {
                let code = try await service.requestCode()
                if Task.isCancelled { return }
                phase = .waiting(code)

                let tokens = try await service.poll(
                    deviceCode: code.deviceCode,
                    interval: code.interval
                )
                if Task.isCancelled { return }

                // Adds the profile the tokens belong to and switches to it. This also fetches
                // the account's name and avatar, so the wait stays on this screen rather than
                // landing on a feed above an unlabelled avatar.
                await authStore.signIn(tokens: tokens)
                onDismiss?()
            } catch {
                // View disappeared or flow restarted — nothing to show.
                if isCancellation(error) { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                phase = .failed(message)
            }
        }
    }

    // MARK: - Formatting helpers

    /// Insert a space in the middle of the code for cross-the-room legibility.
    private func spacedCode(_ code: String) -> String {
        let trimmed = code.replacingOccurrences(of: " ", with: "")
        guard trimmed.count > 4 else { return trimmed }
        let mid = trimmed.index(trimmed.startIndex, offsetBy: trimmed.count / 2)
        return "\(trimmed[..<mid]) \(trimmed[mid...])"
    }

    /// Strip the scheme for a cleaner on-screen URL.
    private func displayURL(_ url: String) -> String {
        url
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    /// Deep link that pre-fills the activation code when scanned.
    private func activationURL(_ code: DeviceAuthService.DeviceCode) -> String {
        let bare = code.userCode.replacingOccurrences(of: " ", with: "")
        return "https://www.youtube.com/activate?user_code=\(bare)"
    }

    // MARK: - QR generation

    /// Shared across renders — creating a CIContext is expensive.
    private static let ciContext = CIContext()

    private func qrImage(for string: String) -> UIImage? {
        let context = Self.ciContext
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }
        // Scale up so the QR is crisp at 340pt.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
