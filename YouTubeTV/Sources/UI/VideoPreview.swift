import AVFoundation
import SwiftUI
import UIKit

/// The video itself, playing silently in place of a card's thumbnail while that card is focused.
///
/// Deliberately not a cut-down `PlayerView`: there is no transport bar, nothing takes over the
/// audio session, and no watch progress is written. The preview always starts at the top of the
/// video and plays at normal speed; nothing about it is remembered, so opening the video
/// afterwards still resumes wherever the user actually left off.
///
/// The whole lifetime is the view's own: the card only builds this while it holds focus, so
/// losing focus removes the view, cancels an in-flight stream resolution and tears the player
/// down — which is what puts the thumbnail back.
struct VideoPreview: View {
    let video: VideoItem

    @Environment(\.scenePhase) private var scenePhase

    @State private var player: AVPlayer?

    /// Whether the layer has a frame to show yet. Held back until it does so the thumbnail stays
    /// up while the stream resolves, instead of the card flashing black on every focus change.
    @State private var isShowingVideo = false

    var body: some View {
        ZStack {
            if let player {
                PreviewLayer(player: player) { isShowingVideo = true }
            }
        }
        .opacity(isShowingVideo ? 1 : 0)
        .animation(.easeIn(duration: 0.2), value: isShowingVideo)
        // Cancelled by SwiftUI when the card loses focus and drops this view, which is what
        // stops a resolution nobody is waiting for any more.
        .task { await start() }
        // The card underneath a presented player or a backgrounded app can keep its focus state,
        // so leaning on focus alone would leave a preview running under the real playback.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { player?.play() } else { player?.pause() }
        }
        .onDisappear(perform: stop)
    }

    @MainActor
    private func start() async {
        do {
            let stream = try await StreamService().resolveStream(videoId: video.id)
            // Focus may have moved on while the stream was resolving; don't start playing for a
            // card the user has already left.
            guard !Task.isCancelled else { return }
            let asset = AVURLAsset(
                url: stream.url,
                options: [AVURLAssetHTTPUserAgentKey: stream.userAgent])
            let avPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            // Silent, and without touching AVAudioSession: a preview must not interrupt whatever
            // is already playing, and claiming `.playback` stays `PlayerView`'s job for when the
            // video is genuinely opened.
            avPlayer.isMuted = true
            // A card left focused is someone who walked away, not someone watching — let the
            // screen saver come up as it would over a still thumbnail.
            avPlayer.preventsDisplaySleepDuringVideoPlayback = false
            player = avPlayer
            // No seek and no rate change: from the start, at normal speed.
            avPlayer.play()
        } catch {
            // Nothing is shown for a preview that fails to resolve — the card simply keeps its
            // thumbnail, which is what it had anyway.
            #if DEBUG
            if !isCancellation(error) {
                print("[VideoPreview] \(video.id) failed: \(error.localizedDescription)")
            }
            #endif
        }
    }

    private func stop() {
        player?.pause()
        player = nil
        isShowingVideo = false
    }
}

/// Hosts an `AVPlayerLayer` — the bare video surface, with none of `AVPlayerViewController`'s
/// controls or focus behaviour, both of which would fight the card the preview sits inside.
private struct PreviewLayer: UIViewRepresentable {
    let player: AVPlayer
    /// Called once the layer has its first frame, so the caller can fade the video in over the
    /// thumbnail rather than cutting to black and waiting.
    var onReadyForDisplay: () -> Void

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        // Matches the thumbnail's `scaledToFill`, so the artwork and the video occupy the box
        // identically and the cross-fade doesn't shift the image.
        view.playerLayer?.videoGravity = .resizeAspectFill
        attach(player, to: view, context: context)
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        guard view.playerLayer?.player !== player else { return }
        attach(player, to: view, context: context)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func attach(_ player: AVPlayer, to view: PlayerLayerView, context: Context) {
        guard let layer = view.playerLayer else { return }
        layer.player = player
        context.coordinator.observeReadyForDisplay(of: layer, then: onReadyForDisplay)
    }

    /// Holds the KVO registration for as long as the representable's view lives.
    final class Coordinator {
        private var observation: NSKeyValueObservation?

        func observeReadyForDisplay(of layer: AVPlayerLayer, then onReady: @escaping () -> Void) {
            observation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
                guard layer.isReadyForDisplay else { return }
                Task { @MainActor in onReady() }
            }
        }
    }
}

/// A view whose backing layer *is* the player layer, so the video tracks the view's bounds
/// without any layout code of its own.
private final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    /// Optional only to avoid a force cast; `layerClass` above guarantees it is there.
    var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
}
