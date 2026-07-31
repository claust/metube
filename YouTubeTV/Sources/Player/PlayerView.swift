import SwiftUI
import AVKit
import AVFoundation
import UIKit

/// Full-screen player. Resolves a stream URL for the given video and plays it
/// with a native tvOS AVPlayerViewController (scrubbing + remote transport).
struct PlayerView: View {
    let video: VideoItem
    var onClose: () -> Void

    @EnvironmentObject private var watchProgress: WatchProgressStore

    @State private var player: AVPlayer?
    @StateObject private var skipper = SponsorBlockSkipper()
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
                PlayerContainer(player: player, video: video)
                    .ignoresSafeArea()
            }

            if isLoading {
                loadingOverlay
            } else if let loadError {
                errorOverlay(loadError)
            }

            if let skip = skipper.lastSkip {
                skipToast(skip)
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

    /// Confirms a skip actually happened, and says what was cut — without it a sponsor read
    /// simply vanishing looks like the stream glitching.
    private func skipToast(_ skip: SponsorBlockSkipper.Skip) -> some View {
        VStack {
            HStack(spacing: 16) {
                Image(systemName: "forward.fill")
                Text("Skipped \(skip.category.displayName.lowercased()) · \(Int(skip.savedSeconds.rounded()))s")
            }
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 32)
            .padding(.vertical, 18)
            .background(.black.opacity(0.65), in: Capsule())
            .padding(.top, 60)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: skip.id)
        .allowsHitTesting(false)
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

            // Deliberately after playback has started, and not raced against the stream
            // resolution with `async let`: SponsorBlock is a nice-to-have, and waiting on a
            // third-party server before showing the first frame would trade a certain delay
            // for an uncertain benefit. Attaching a second or two in only matters for a
            // segment in the opening seconds — rare, and it still gets skipped on the next
            // tick if playback is still inside it.
            isLoading = false
            await loadSponsorSegments(for: avPlayer)
        } catch {
            // The view was dismissed while loading — not a real error, so don't show the
            // error overlay.
            if isCancellation(error) { return }
            // A real failure: don't hold the audio session while only an error is shown.
            deactivateAudioSession()
            self.loadError = error
        }
    }

    /// Looks up the community's segment list for this video and hands it to the skipper.
    ///
    /// Every failure is swallowed: no segments simply means nothing gets skipped, which is
    /// exactly how the player behaved before. Nothing here is worth an error overlay on a video
    /// that is already playing fine.
    @MainActor
    private func loadSponsorSegments(for player: AVPlayer) async {
        do {
            let segments = try await SponsorBlockService.fetchSegments(videoId: video.id)
            // The view can be dismissed, or `load()` can have re-run and built a new player,
            // while the request was in flight — attaching to a player nobody is watching would
            // leave a periodic observer running on it.
            guard !Task.isCancelled, self.player === player else { return }
            skipper.attach(to: player, segments: segments)
            #if DEBUG
            print("[SponsorBlock] \(segments.count) segment(s) for \(video.id)")
            #endif
        } catch {
            #if DEBUG
            if !isCancellation(error) {
                print("[SponsorBlock] lookup failed: \(error.localizedDescription)")
            }
            #endif
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
        // Same reasoning, and it has to happen before `player` is dropped — the skipper only
        // holds it weakly and can't hand its own token back once it's gone.
        skipper.detach()
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
    let video: VideoItem

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.transportBarCustomMenuItems = [commentsButton(for: controller)]
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }

    /// The "Comments" control in the transport bar's row of buttons, alongside the system's
    /// subtitle and audio ones. Selecting it lays the comments panel over the playing video.
    ///
    /// Presented from the player controller rather than composed into the SwiftUI overlay
    /// stack because focus is the whole game on tvOS: AVPlayerViewController owns focus while
    /// it's on screen, and a presented controller is the supported way to take it — and Menu
    /// then returns it to the player by plain dismissal.
    private func commentsButton(for controller: AVPlayerViewController) -> UIMenuElement {
        let videoId = video.id
        return UIAction(
            title: "Comments",
            image: UIImage(systemName: "text.bubble")
        ) { [weak controller] _ in
            guard let controller, controller.presentedViewController == nil else { return }
            let overlay = CommentsOverlayView(videoId: videoId) { [weak controller] in
                controller?.dismiss(animated: true)
            }
            let host = UIHostingController(rootView: overlay)
            // Over the video, not instead of it: playback continues, visible to the left of
            // the panel and dimly through it.
            host.modalPresentationStyle = .overFullScreen
            host.view.backgroundColor = .clear
            controller.present(host, animated: true)
        }
    }
}
