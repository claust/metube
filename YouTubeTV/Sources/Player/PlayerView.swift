import SwiftUI
import AVKit
import AVFoundation

/// Full-screen player. Resolves a stream URL for the given video and plays it
/// with a native tvOS AVPlayerViewController (scrubbing + remote transport).
struct PlayerView: View {
    let video: VideoItem
    var onClose: () -> Void

    @EnvironmentObject private var watchProgress: WatchProgressStore

    @State private var player: AVPlayer?
    @State private var loadError: Error?
    @State private var isLoading = true
    @State private var didPlayToEndObserver: NSObjectProtocol?
    /// The periodic observer token together with the player it came from: a token is only
    /// valid for the player that vended it, and `load()` can re-run and build a new one.
    @State private var timeObserver: (player: AVPlayer, token: Any)?
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
            // The view may have been dismissed while awaiting the resolved stream; bail out
            // before taking over audio output or starting playback for a view that's gone.
            guard !Task.isCancelled else { return }
            // Only take over audio output once we actually have a playable stream.
            activateAudioSession()
            // Keep CoreMedia's media requests on the same client identity that minted the URL.
            // AVURLAssetHTTPUserAgentKey is public API (tvOS 16+); the more general
            // AVURLAssetHTTPHeaderFieldsKey is an undocumented string key, so a typo in it would
            // silently drop the headers instead of failing to compile.
            let asset = AVURLAsset(
                url: stream.url,
                options: [
                    AVURLAssetHTTPUserAgentKey: stream.userAgent
                ])
            let item = AVPlayerItem(asset: asset)
            let avPlayer = AVPlayer(playerItem: item)
            // Queued before the item is ready to play; AVPlayer applies it once it is, so the
            // transport bar comes up already parked where the user left off.
            if let resume = watchProgress.resumePosition(for: video.id) {
                avPlayer.seek(
                    to: CMTime(seconds: resume, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero,
                    completionHandler: { _ in })
            }
            observePlaybackEnd(of: item)
            observePlaybackPosition(of: avPlayer)
            #if DEBUG
            observeDeliveredResolution(of: item, adaptive: stream.isAdaptive)
            #endif
            self.player = avPlayer
            avPlayer.play()
        } catch {
            // The view was dismissed while loading — not a real error, so don't show the
            // error overlay.
            if isCancellation(error) { return }
            // A real failure: don't hold the audio session while only an error is shown.
            deactivateAudioSession()
            self.loadError = error
        }
    }

    /// Returns to the home screen automatically once the video finishes playing.
    @MainActor
    private func observePlaybackEnd(of item: AVPlayerItem) {
        if let didPlayToEndObserver {
            NotificationCenter.default.removeObserver(didPlayToEndObserver)
        }
        // Capture onClose explicitly rather than self, which also holds the AVPlayer and
        // would otherwise be captured just to reach this one closure property.
        let onClose = onClose
        let videoId = video.id
        let watchProgress = watchProgress
        let fallbackDuration = video.durationSeconds ?? 0
        didPlayToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                // Watched through: the card keeps a full red line, and playing it again starts
                // from the top rather than the last few seconds.
                let duration = (notification.object as? AVPlayerItem)?.duration.seconds ?? .nan
                watchProgress.markFinished(
                    videoId: videoId,
                    duration: duration.isFinite ? duration : fallbackDuration)
            }
            onClose()
        }
    }

    /// Saves the playback position periodically, so a video abandoned by pulling the plug (or
    /// by the app being killed) still resumes near where it was left.
    @MainActor
    private func observePlaybackPosition(of player: AVPlayer) {
        removeTimeObserver()
        let videoId = video.id
        let fallbackDuration = video.durationSeconds ?? 0
        let token = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 5, preferredTimescale: 1),
            queue: .main
        ) { [weak player] time in
            guard let player else { return }
            MainActor.assumeIsolated {
                let itemDuration = player.currentItem?.duration.seconds ?? .nan
                watchProgress.record(
                    videoId: videoId,
                    position: time.seconds,
                    duration: itemDuration.isFinite ? itemDuration : fallbackDuration)
            }
        }
        timeObserver = (player, token)
    }

    /// Hands the token back to the player that issued it — passing it to any other instance
    /// is a crash.
    @MainActor
    private func removeTimeObserver() {
        guard let timeObserver else { return }
        timeObserver.player.removeTimeObserver(timeObserver.token)
        self.timeObserver = nil
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
            print(
                String(
                    format: "[PlayerView] %@ delivering %dx%d (indicated %.1f Mbps)",
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

    @MainActor
    private func teardown() {
        // The exact position at the moment of leaving — the periodic observer's last tick can
        // be up to five seconds stale.
        if let player, let item = player.currentItem {
            let duration = item.duration.seconds
            watchProgress.record(
                videoId: video.id,
                position: player.currentTime().seconds,
                duration: duration.isFinite ? duration : (video.durationSeconds ?? 0))
        }
        // Unconditionally: the observer belongs to the player, not to its item, so an item
        // that has gone away must not leave it installed.
        removeTimeObserver()
        if let didPlayToEndObserver {
            NotificationCenter.default.removeObserver(didPlayToEndObserver)
            self.didPlayToEndObserver = nil
        }
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
