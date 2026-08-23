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
    @EnvironmentObject private var watchHistory: WatchHistoryStore

    @State private var player: AVPlayer?
    @StateObject private var skipper = SponsorBlockSkipper()
    /// Whether the comments panel is up. Shared with `PlayerContainer`, which presents it.
    @StateObject private var comments = CommentsPresentation()
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
                PlayerContainer(player: player, video: video, comments: comments)
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

    /// How long a resolved stream gets to actually start playing before it is written off and
    /// the next client in the ladder is tried.
    ///
    /// Sized to come in under CoreMedia's own ~20s index-file timeout, because that timeout is
    /// not dependable: a manifest whose renditions 404 (rather than hang) leaves AVPlayer
    /// retrying inside its penalty-box logic indefinitely, never marking the item `.failed`.
    /// The cost of being wrong is a video that was merely slow dropping to the 360p fallback,
    /// which still plays.
    private static let playbackStartTimeout: Duration = .seconds(15)

    /// How often `awaitPlaybackStart` re-checks while waiting.
    private static let playbackStartPollInterval: Duration = .milliseconds(250)

    /// Whether an attempt got off the ground.
    private enum PlaybackStart {
        case started
        /// Never played. Carries AVFoundation's reason when it had one — a stream that simply
        /// hangs produces no error at all, hence the optional.
        case failed(Error?)
        case cancelled
    }

    @MainActor
    private func load() async {
        // Reset state up front so a re-run (e.g. SwiftUI restarting the .task) can't leave a
        // stale error overlay or a previous player instance around.
        isLoading = true
        loadError = nil
        player = nil
        defer { isLoading = false }

        // The failure worth showing is the first one: it comes from the preferred client, so it
        // carries a better explanation than "the 360p fallback didn't work either".
        var firstFailure: Error?
        var failedClient: AppConfig.Client?

        while true {
            do {
                let stream = try await StreamService().resolveStream(
                    videoId: video.id, after: failedClient)
                // The view may have been dismissed while awaiting the resolved stream; bail out
                // before taking over audio output or starting playback for a view that's gone.
                guard !Task.isCancelled else { return }
                let avPlayer = startPlayback(of: stream)

                switch await awaitPlaybackStart(of: avPlayer) {
                case .started:
                    // Frames are moving, so this is a video that was watched — which is the point
                    // the History screen's list is written from. A card that never resolved a
                    // playable stream doesn't belong on it.
                    watchHistory.record(video)
                    // Deliberately after playback has started, and not raced against the stream
                    // resolution with `async let`: SponsorBlock is a nice-to-have, and waiting on
                    // a third-party server before showing the first frame would trade a certain
                    // delay for an uncertain benefit. Attaching a second or two in only matters
                    // for a segment in the opening seconds — rare, and it still gets skipped on
                    // the next tick if playback is still inside it.
                    isLoading = false
                    await loadSponsorSegments(for: avPlayer)
                    return
                case .cancelled:
                    // Nothing is waiting on this attempt any more, and it never started playing.
                    // `onDisappear` would tear it down too, but only once SwiftUI gets round to
                    // it — until then a half-started player would keep its observers installed
                    // behind whatever replaces it.
                    discardAttempt(avPlayer)
                    return
                case .failed(let error):
                    // This URL resolved but won't play, so the same client has nothing better to
                    // offer — drop it and pick the ladder up at the next one. The loading overlay
                    // stays up meanwhile rather than showing the dead player behind it.
                    discardAttempt(avPlayer)
                    if firstFailure == nil { firstFailure = error ?? StreamError.stalled }
                    failedClient = stream.client
                }
            } catch {
                // The view was dismissed while loading — not a real error, so don't show the
                // error overlay.
                if isCancellation(error) { return }
                // A real failure: don't hold the audio session while only an error is shown.
                deactivateAudioSession()
                // `error` here is the ladder running out (`.noStream`) whenever an earlier
                // attempt already failed, so prefer that attempt's reason.
                self.loadError = firstFailure ?? error
                return
            }
        }
    }

    /// Builds a player for a resolved stream, wires up the observers that follow it, and starts
    /// it going.
    @MainActor
    private func startPlayback(of stream: ResolvedStream) -> AVPlayer {
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
        // Criteria before attaching the item to the player, so there is no window — however
        // theoretical — in which the item could reach ready-to-play with no audio preference set.
        let avPlayer = AVPlayer()
        selectAudioLanguage(original: stream.originalAudioLanguage, on: avPlayer)
        avPlayer.replaceCurrentItem(with: item)
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
        return avPlayer
    }

    /// Asks for the viewer's languages in the order they ranked them, and the video's own language
    /// after all of them.
    ///
    /// On a dubbed video AVFoundation gets no help from the playlist: every rendition is marked
    /// `DEFAULT=NO`, so with nothing matching the viewer's languages it falls back to the first
    /// autoselectable one. The renditions are ordered alphabetically by language code with the
    /// original appended last, so that fallback is reliably a dub, and whichever dub sorts first:
    /// German on a video dubbed into German and nothing earlier, Arabic the moment there is an
    /// `ar` track. Only the fallback is wrong, and only the fallback is replaced here — a viewer
    /// whose own language *is* among the dubs keeps getting it, as they did before.
    ///
    /// Settings › General › Apple TV Language is an ordered list, not a single choice, and
    /// `preferredLanguages` takes languages "in order of desirability", so the ranking carries
    /// across as it stands. `Locale.preferredLanguages` and not
    /// `Bundle.main.preferredLocalizations`: the latter is filtered down to what the app itself
    /// is localised for, which has nothing to do with what audio the viewer can follow.
    ///
    /// The video's own language comes from `StreamService`, which read it from the API — where the
    /// fact survives — and it goes last, so it decides only when nothing the viewer asked for is
    /// on offer.
    ///
    /// Criteria rather than `AVPlayerItem.select(_:in:)`, for the timing: criteria are applied
    /// "when [the item] is made ready to play", so the choice is in place before the first sample
    /// is rendered. Selecting explicitly would mean loading the media selection group first, which
    /// cannot be awaited without either delaying playback — the one thing `playbackStartTimeout`
    /// exists to bound — or racing it, and losing that race is an audible moment of the wrong
    /// language. `appliesMediaSelectionCriteriaAutomatically` stays on, since it is what applies
    /// these at all, and only the audible group is given criteria — subtitles keep following the
    /// viewer's own settings.
    ///
    /// Best-effort: an undubbed video has one track and nothing to choose, and a language the
    /// manifest doesn't carry leaves AVFoundation's own choice standing. Silence would be worse
    /// than the wrong language.
    private func selectAudioLanguage(original: String?, on player: AVPlayer) {
        guard let original else { return }
        player.setMediaSelectionCriteria(
            AVPlayerMediaSelectionCriteria(
                preferredLanguages: Locale.preferredLanguages + [original],
                preferredMediaCharacteristics: nil),
            forMediaCharacteristic: .audible)
    }

    /// Waits for a freshly started attempt to either play or prove that it won't.
    ///
    /// Polled rather than observed: the three things worth watching (the item failing, the
    /// player reaching `.playing`, and the deadline passing) would otherwise need two KVO
    /// observations and a timer feeding one continuation that must resume exactly once. A
    /// quarter-second tick over at most `playbackStartTimeout` costs nothing and picks up task
    /// cancellation for free.
    ///
    /// Timed on `ContinuousClock` rather than `Date`, which is not monotonic: a TV that syncs
    /// its clock shortly after a cold boot can step wall time, and a backwards step larger than
    /// the timeout would leave a `Date` deadline permanently in the future — no fallback, and
    /// the black screen this whole path exists to avoid.
    @MainActor
    private func awaitPlaybackStart(of player: AVPlayer) async -> PlaybackStart {
        let deadline = ContinuousClock.now + Self.playbackStartTimeout
        while true {
            if Task.isCancelled { return .cancelled }
            // Frames are moving — anything short of this (`.waitingToPlayAtSpecifiedRate` in
            // particular) is exactly the state a stream stuck behind 404s sits in.
            if player.timeControlStatus == .playing { return .started }
            if let item = player.currentItem, item.status == .failed {
                return .failed(item.error)
            }
            guard ContinuousClock.now < deadline else {
                return .failed(player.currentItem?.error)
            }
            try? await Task.sleep(for: Self.playbackStartPollInterval)
        }
    }

    /// Detaches everything `startPlayback` attached and drops the player, leaving the view ready
    /// for the next attempt. Safe to run after `teardown` has already been through: every step
    /// is guarded on state that teardown clears.
    ///
    /// Deliberately leaves the audio session alone. A retry needs it, and on the cancellation
    /// path `teardown` is the one that gives it up — releasing it here would hand audio back
    /// mid-dismissal for no gain.
    @MainActor
    private func discardAttempt(_ avPlayer: AVPlayer) {
        removeTimeObserver()
        skipper.detach()
        if let didPlayToEndObserver {
            NotificationCenter.default.removeObserver(didPlayToEndObserver)
            self.didPlayToEndObserver = nil
        }
        #if DEBUG
        resolutionObservation?.invalidate()
        resolutionObservation = nil
        #endif
        avPlayer.pause()
        player = nil
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

    /// Returns to the home screen automatically once the video finishes playing — unless the
    /// comments panel is up, in which case the player just stops on its last frame.
    ///
    /// Someone reading the comments isn't done with the screen because the video is: the video
    /// running out mid-thread would otherwise pull the panel away and lose their place.
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
        let comments = comments
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
                // Only the automatic exit is suppressed, never a deliberate one: Menu still
                // leaves, from the panel and then from the stopped player, as it always did.
                guard !comments.isPresented else { return }
                onClose()
            }
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
    /// Written here, read by the player: whether the comments panel is currently over the video.
    let comments: CommentsPresentation

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
        let comments = self.comments
        return UIAction(
            title: "Comments",
            image: UIImage(systemName: "text.bubble")
        ) { [weak controller] _ in
            guard let controller, controller.presentedViewController == nil else { return }
            let overlay = CommentsOverlayView(videoId: videoId) { [weak controller] in
                controller?.dismiss(animated: true)
            }
            let host = CommentsHostingController(rootView: overlay, presentation: comments)
            // Over the video, not instead of it: playback continues, visible to the left of
            // the panel and dimly through it.
            host.modalPresentationStyle = .overFullScreen
            host.view.backgroundColor = .clear
            // Eagerly, rather than waiting for the presentation animation: a video that ends
            // during it must already count as "something is over the player".
            comments.isPresented = true
            controller.present(host, animated: true)
        }
    }
}

/// Whether the comments panel is over the video right now.
///
/// The panel is presented by `PlayerContainer` but matters to `PlayerView`, which must not walk
/// out from under it when the video ends. Deliberately not `@Published`: nothing draws from it,
/// so republishing would invalidate the player view for no reason.
@MainActor
private final class CommentsPresentation: ObservableObject {
    var isPresented = false
}

/// Hosts the comments panel and reports when it has gone.
///
/// `viewDidDisappear` rather than the dismissal's completion handler, so the flag clears
/// however the panel goes away — the overlay's own Menu press, its "Close" button, or the
/// player being torn down underneath it.
private final class CommentsHostingController: UIHostingController<CommentsOverlayView> {
    private let presentation: CommentsPresentation

    init(rootView: CommentsOverlayView, presentation: CommentsPresentation) {
        self.presentation = presentation
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        presentation.isPresented = false
    }
}
