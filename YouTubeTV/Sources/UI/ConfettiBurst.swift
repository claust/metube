import SwiftUI

/// A one-shot spray of paper from the middle of whatever it is overlaid on.
///
/// Purely decorative: it draws outside its own bounds, takes no focus and no hits, and occupies
/// no layout space, so hanging it on a view never moves that view.
///
/// The flight is driven off a `TimelineView` clock rather than an implicit animation on a
/// progress property: fifty pieces each need position, spin and fade derived from the same
/// time value, and reading that time per frame is both simpler than animating it and immune to
/// the surrounding transaction — the burst is fired from inside another animation, which is
/// exactly the case where an implicit one goes missing.
struct ConfettiBurst: View {
    /// Flip to `true` to fire. Flipping back to `false` and up again fires it afresh.
    let isActive: Bool

    /// When the current burst started, and `nil` when none is in the air — which also parks
    /// the timeline, so an idle clock isn't redrawing this sixty times a second.
    @State private var start: Date?

    /// The pieces, randomised once. Re-rolling them per burst would look more varied, but a
    /// fixed set means the burst can't accidentally land the same shape twice in a row while
    /// the animation is still running.
    @State private var pieces: [Piece] = (0..<56).map { _ in Piece() }

    /// How long a piece is in the air.
    private static let flightDuration: TimeInterval = 2.2

    private struct Piece: Identifiable {
        let id = UUID()
        /// A wide fan pointing down and into the screen. A popper would throw upward, but this
        /// hangs off the top-right corner, where up is off the edge and left is the only
        /// direction with any screen in it — so the paper is thrown down and inward instead.
        let angle = Double.random(in: 25...170) * .pi / 180
        let distance = CGFloat.random(in: 120...440)
        let width = CGFloat.random(in: 8...16)
        let height = CGFloat.random(in: 12...26)
        let spin = Double.random(in: -900...900)
        /// Staggers the launch so the burst has a front and a tail rather than one flat wall.
        let delay = CGFloat.random(in: 0...0.22)
        let color = Color(
            hue: Double.random(in: 0...1),
            saturation: Double.random(in: 0.65...1),
            brightness: 1
        )
    }

    var body: some View {
        TimelineView(.animation(paused: start == nil)) { context in
            let progress = progress(at: context.date)
            ZStack {
                ForEach(pieces) { piece in
                    let time = travel(piece, progress)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(piece.color)
                        .frame(width: piece.width, height: piece.height)
                        .rotationEffect(.degrees(piece.spin * time))
                        // Squashes the rectangle as it spins, which reads as paper tumbling
                        // edge-on without the cost of drawing it in 3D.
                        .scaleEffect(x: cos(piece.spin * time * .pi / 180), y: 1)
                        .offset(
                            x: cos(piece.angle) * piece.distance * time,
                            // The throw, plus gravity pulling it back down — squared, so the
                            // pieces carry away fast and then sag out of the air.
                            y: sin(piece.angle) * piece.distance * time + 420 * time * time
                        )
                        .opacity(fade(time))
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: isActive) { _, active in
            start = active ? .now : nil
        }
    }

    /// 0 through 1 across the flight, clamped at both ends.
    private func progress(at date: Date) -> CGFloat {
        guard let start else { return 0 }
        return min(1, max(0, CGFloat(date.timeIntervalSince(start) / Self.flightDuration)))
    }

    /// This piece's own 0–1 progress, once its stagger has elapsed.
    private func travel(_ piece: Piece, _ progress: CGFloat) -> CGFloat {
        // Eased out: paper leaves fast and coasts, rather than travelling at a constant rate.
        let time = max(0, (progress - piece.delay) / (1 - piece.delay))
        return 1 - pow(1 - time, 2)
    }

    /// Solid for most of the flight, then out — a burst that vanishes mid-air looks like a
    /// dropped frame, and one that stays to the end leaves paper sitting on the screen.
    private func fade(_ time: CGFloat) -> Double {
        time <= 0 ? 0 : Double(min(1, (1 - time) / 0.35))
    }
}
