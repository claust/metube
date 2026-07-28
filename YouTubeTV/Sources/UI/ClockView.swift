import SwiftUI

/// The wall clock, tucked into the top-right corner of the app.
///
/// A tvOS app owns the whole screen, so there is no system status bar to read the time from —
/// and a living room screen is exactly where someone glances up to check it. Set in heavy
/// monospaced digits so it reads from the sofa and the minute change doesn't shift the layout.
///
/// Once a day, at 21:21, the clock makes a short, silent fuss of itself — see `celebrationTime`.
struct ClockView: View {
    /// The minute currently on screen. Only the displayed minute is kept — the per-second
    /// samples are compared against it and dropped, so the view rebuilds sixty times less
    /// often than it is polled, and every rebuild it does do is a visible change worth
    /// animating.
    @State private var now = Date()

    /// True for the few seconds the clock is celebrating: grown to double size, with confetti
    /// in the air.
    @State private var isCelebrating = false

    /// Ends the celebration. Held so a second trigger can cancel the first one's countdown
    /// rather than have it cut the new burst short.
    @State private var celebrationEnd: Task<Void, Never>?

    /// Polls once a second. A minute-aligned timer would be leaner, but it drifts across a
    /// resume, and a clock that turns over a few seconds late is the one bug a clock can't have.
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// The minute the clock celebrates: 21:21, on the 24-hour clock the app doesn't necessarily
    /// display — the moment is the moment whether or not the user reads it as 9:21 pm.
    private static let celebrationTime = (hour: 21, minute: 21)

    /// How long the clock stays big. Long enough to look at, short enough that a glance up
    /// half a minute later finds an ordinary clock again.
    private static let celebrationDuration = Duration.seconds(3.2)

    var body: some View {
        Text(now, format: .dateTime.hour().minute())
            .font(.system(size: 52, weight: .black, design: .rounded))
            // Digits of equal width, so the frame stays put as the time changes.
            .monospacedDigit()
            // Rolls the changed digits over rather than swapping them: the ones that didn't
            // change stay perfectly still, which is what makes the turn read as a clock
            // ticking rather than a label being replaced.
            .contentTransition(.numericText(countsDown: false))
            .foregroundStyle(.white)
            // Enough to stay legible over a bright thumbnail without competing with the feed.
            .shadow(color: .black.opacity(0.6), radius: 8, y: 2)
            // Anchored to the corner it lives in, so growing pushes the clock into the screen
            // instead of off the top-right edge.
            .scaleEffect(isCelebrating ? 2 : 1, anchor: .topTrailing)
            .overlay { ConfettiBurst(isActive: isCelebrating) }
            .onReceive(tick) { date in
                // Same minute as the one on screen, so there is nothing to redraw.
                guard !Calendar.current.isDate(date, equalTo: now, toGranularity: .minute) else {
                    return
                }
                // Unhurried on purpose: the turn is the only thing this view ever does, and at
                // a glance-up distance a quick one is over before the eye arrives.
                withAnimation(.smooth(duration: 1.1)) { now = date }
                if isCelebrationTime(date) {
                    celebrate()
                }
            }
            // It is decoration next to everything else on screen; VoiceOver users get the time
            // from the system, and reading it out on every focus move would be noise.
            .accessibilityHidden(true)
            // Waiting for 21:21 to see the celebration is no way to work on it, so this replays
            // it on a loop instead:
            //   make run ARGS="-clockCelebrationDemo"
            .task {
                guard ProcessInfo.processInfo.arguments.contains("-clockCelebrationDemo") else {
                    return
                }
                while !Task.isCancelled {
                    celebrate()
                    try? await Task.sleep(for: .seconds(8))
                }
            }
    }

    private func isCelebrationTime(_ date: Date) -> Bool {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return parts.hour == Self.celebrationTime.hour && parts.minute == Self.celebrationTime.minute
    }

    /// Grows the clock and fires the confetti, then puts both back. Silent on purpose: a TV
    /// app that makes a noise of its own over whatever is playing is an app people turn off.
    private func celebrate() {
        // A spring rather than a curve: the overshoot is what sells the pop, and the clock is
        // the one thing on screen allowed to be theatrical.
        withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { isCelebrating = true }
        celebrationEnd?.cancel()
        celebrationEnd = Task {
            try? await Task.sleep(for: Self.celebrationDuration)
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.6)) { isCelebrating = false }
        }
    }
}
