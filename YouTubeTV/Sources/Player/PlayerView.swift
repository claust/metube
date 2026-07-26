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
    #if DEBUG
    @State private var resolutionObservation: NSKeyValueObservation?
    #endif

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

        do {
            let stream = try await StreamService().resolveStream(videoId: video.id)
            // Only take over audio output once we actually have a playable stream.
            activateAudioSession()
            // The stream URLs are minted for a specific InnerTube client; the manifest host
            // rejects requests whose User-Agent doesn't match, so pass it down to CoreMedia.
            let asset = AVURLAsset(url: stream.url, options: [
                "AVURLAssetHTTPHeaderFieldsKey": stream.httpHeaders
            ])
            let item = AVPlayerItem(asset: asset)
            let avPlayer = AVPlayer(playerItem: item)
            #if DEBUG
            observeDeliveredResolution(of: item, adaptive: stream.isAdaptive)
            #endif
            self.player = avPlayer
            avPlayer.play()
        } catch {
            // The view was dismissed while loading (cancellation surfaces as CancellationError
            // or URLError.cancelled) — not a real error, so don't show the error overlay.
            if Task.isCancelled { return }
            // A real failure: don't hold the audio session while only an error is shown.
            deactivateAudioSession()
            self.loadError = error
        }
    }

    #if DEBUG
    /// Logs the resolution actually being delivered. `presentationSize` is the ground truth —
    /// for an HLS stream it updates on every ABR variant switch, so this shows the ladder
    /// climbing rather than just the first variant chosen.
    @MainActor
    private func observeDeliveredResolution(of item: AVPlayerItem, adaptive: Bool) {
        let kind = adaptive ? "HLS" : "progressive"
        resolutionObservation = item.observe(\.presentationSize, options: [.initial, .new]) { item, _ in
            let size = item.presentationSize
            guard size != .zero else { return }
            let bitrate = item.accessLog()?.events.last?.indicatedBitrate ?? 0
            print(String(format: "[PlayerView] %@ delivering %dx%d (indicated %.1f Mbps)",
                         kind, Int(size.width), Int(size.height), bitrate / 1_000_000))
        }
    }
    #endif

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback)
            try session.setActive(true)
        } catch {
            #if DEBUG
            print("[PlayerView] AVAudioSession activation failed: \(error.localizedDescription)")
            #endif
        }
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    private func teardown() {
        #if DEBUG
        resolutionObservation?.invalidate()
        resolutionObservation = nil
        #endif
        player?.pause()
        player = nil
        deactivateAudioSession()
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
