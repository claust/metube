import AVFoundation
import Combine
import Foundation

/// Watches playback and seeks past SponsorBlock segments as they come up.
///
/// Polls rather than using `addBoundaryTimeObserver`: boundary observers fire on the *segment
/// start* only, so any way of entering a segment other than playing into its first frame — a
/// resume position that lands mid-sponsor, the user scrubbing into one — would sail straight
/// through it. A quarter-second tick catches every entry for the price of one comparison
/// against a handful of ranges.
///
/// Each segment is skipped at most once per playback. Otherwise rewinding into a segment the
/// user *wants* to see (to re-read a sponsor's discount code, or because the timestamps are
/// wrong) would slam them forward again on every attempt, with no way out.
@MainActor
final class SponsorBlockSkipper: ObservableObject {

    /// The most recent skip, for the on-screen toast. Cleared a few seconds later.
    @Published private(set) var lastSkip: Skip?
    /// Everything known for the current video, for the transport-bar markers.
    @Published private(set) var segments: [SponsorSegment] = []

    struct Skip: Identifiable, Equatable {
        let id: String
        let category: SponsorCategory
        let savedSeconds: TimeInterval
    }

    private weak var player: AVPlayer?
    private var observerToken: Any?
    private var skipped: Set<String> = []
    private var toastTask: Task<Void, Never>?

    /// How long the "skipped …" toast stays up.
    private static let toastDuration: Duration = .seconds(3)

    // MARK: - Lifecycle

    /// Starts watching `player`. Safe to call again — it replaces any previous attachment.
    func attach(to player: AVPlayer, segments: [SponsorSegment]) {
        detach()
        guard !segments.isEmpty else { return }
        self.player = player
        self.segments = segments
        observerToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 4),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.playbackAdvanced(to: time.seconds) }
        }
    }

    func detach() {
        // The token belongs to the player that vended it; handing it to another instance is a
        // crash, and the player may already be gone.
        if let observerToken, let player {
            player.removeTimeObserver(observerToken)
        }
        observerToken = nil
        player = nil
        segments = []
        skipped = []
        toastTask?.cancel()
        toastTask = nil
        lastSkip = nil
    }

    deinit {
        toastTask?.cancel()
    }

    // MARK: - Skipping

    private func playbackAdvanced(to time: TimeInterval) {
        guard time.isFinite, let player else { return }
        guard let segment = segments.first(where: { $0.contains(time) && !skipped.contains($0.id) })
        else { return }

        skipped.insert(segment.id)

        // A segment running to the end of the video has nothing to seek to — seeking to the
        // duration itself is where AVPlayer's end-of-item handling gets unreliable. Pausing at
        // the last frame is what "the video is over" looks like, and PlayerView's end-of-play
        // observer still fires from the seek.
        let duration = player.currentItem?.duration.seconds ?? .nan
        let target = duration.isFinite ? min(segment.end, duration) : segment.end

        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero,
            completionHandler: { _ in })

        #if DEBUG
        print(
            String(
                format: "[SponsorBlock] skipped %@ at %.1fs → %.1fs (%.0fs)",
                segment.category.rawValue, time, target, segment.duration))
        #endif

        show(Skip(id: segment.id, category: segment.category, savedSeconds: segment.duration))
    }

    private func show(_ skip: Skip) {
        lastSkip = skip
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: Self.toastDuration)
            guard !Task.isCancelled else { return }
            // Only clear the toast that this task put up — a skip that landed while we slept
            // owns the toast now and has its own timer running.
            if self?.lastSkip?.id == skip.id { self?.lastSkip = nil }
        }
    }
}
