import SwiftUI
import AVKit
import AVFoundation

/// Full-screen player. Resolves a stream URL for the given video and plays it
/// with a native tvOS AVPlayerViewController (scrubbing + remote transport).
struct PlayerView: View {
    let video: VideoItem
    var onClose: () -> Void

    @State private var player: AVPlayer?
    @State private var loadError: Error?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                PlayerContainer(player: player)
                    .ignoresSafeArea()
            }

            if isLoading {
                loadingOverlay
            } else if let loadError {
                errorOverlay(loadError)
            }
        }
        .task { await load() }
        .onDisappear { teardown() }
    }

    // MARK: - Subviews

    private var loadingOverlay: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.5)
            Text(video.title)
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }

    private func errorOverlay(_ error: Error) -> some View {
        VStack(spacing: 32) {
            Text(video.title)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Text(error.localizedDescription)
                .font(.title3)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 120)

            Button("Back", action: onClose)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }

    // MARK: - Lifecycle

    @MainActor
    private func load() async {
        // Reset state up front so a re-run (e.g. SwiftUI restarting the .task) can't leave a
        // stale error overlay or a previous player instance around.
        isLoading = true
        loadError = nil
        player = nil
        defer { isLoading = false }

        configureAudioSession()
        do {
            let url = try await StreamService().resolveStreamURL(videoId: video.id)
            let avPlayer = AVPlayer(url: url)
            self.player = avPlayer
            avPlayer.play()
        } catch {
            self.loadError = error
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback)
            try session.setActive(true)
        } catch {
            #if DEBUG
            print("[PlayerView] AVAudioSession configuration failed: \(error.localizedDescription)")
            #endif
        }
    }

    private func teardown() {
        player?.pause()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}

/// Wraps AVPlayerViewController for the native tvOS playback experience
/// (transport bar, scrubbing, play/pause with the Siri Remote).
private struct PlayerContainer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }
}
