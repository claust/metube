import SwiftUI

/// The rolling news ticker across the top of Home: a yellow strip of headlines drifting
/// right-to-left, with the source badge pinned at the left so a half-scrolled headline is still
/// attributable.
///
/// Focus is what stops it. Unfocused it rolls; the moment it takes focus the motion freezes,
/// the headline at the left edge is lifted onto a white chip — the focus cue goes on the one
/// story being read, not around the whole strip — and a reading panel opens underneath with
/// that story's picture and its full text, fetched from the outlet's own page.
///
/// The directional pad covers the whole of it: left and right step between stories, and down
/// walks into the article and keeps walking, a paragraph at a time, scrolling as it goes. Down
/// off the end of the article lands on the feed; Menu leaves at any point and puts focus on the
/// first video. Reading the news never means leaving Home — there is nothing to open, and the
/// way out is the button that already means "out".
///
/// The scroll is a single continuous lap rather than a per-headline animation: two identical
/// lanes sit side by side and the pair is offset by the distance travelled, taken modulo one
/// lane's width. As lane one leaves to the left, lane two has already taken its place, so the
/// wrap point is invisible and there is no restart to hide.
struct NewsBanner: View {
    var items: [NewsItem]
    /// Whether the feed behind the banner should stop scrolling — see `isFeedLocked`. Reported
    /// rather than acted on, because the scroll view belongs to the screen, not to the strip.
    var onFeedLockChange: (Bool) -> Void = { _ in }
    /// Whether the banner is in use — the strip focused, or a story being read. The screen uses
    /// it to hold fresh headlines back rather than swapping them in mid-sentence.
    var onActiveChange: (Bool) -> Void = { _ in }
    /// Menu, pressed anywhere in the strip or the article. The screen showing the banner owns
    /// where focus goes next — it is the only thing that knows what the feed's first card is.
    var onDismiss: () -> Void = {}

    /// How fast the strip travels, in points per second. Slow enough to finish reading a
    /// headline that is already halfway across, brisk enough that the next one is not a wait.
    private static let speed: CGFloat = 110

    private static let height: CGFloat = 76

    /// BBC-ticker yellow. Warm rather than lemon, so black text on it stays high-contrast.
    private static let bannerYellow = Color(red: 0.98, green: 0.80, blue: 0.09)

    /// Width of each headline cell, by item id, filled as the cells lay out.
    ///
    /// The lap length is the sum of these, and the chip needs to know where each cell starts —
    /// neither is knowable from the text without measuring it, so the strip stays still until
    /// every cell has reported in (see `laneWidth`).
    @State private var cellWidths: [String: CGFloat] = [:]

    /// Distance travelled as of the last pause, already reduced modulo `laneWidth`. The whole
    /// of the position while paused; the starting point of the sum while running.
    @State private var base: CGFloat = 0

    /// When the current run began, and `nil` while paused. Deriving position from this rather
    /// than accumulating it per frame means the strip can't drift, and a dropped frame costs
    /// nothing.
    @State private var runStart: Date?

    /// What inside the banner holds focus, and `nil` when nothing does.
    ///
    /// The article is chopped into screenful-ish steps, each a focus target in its own right —
    /// that is what makes down scroll the story rather than leave it. tvOS keeps the focused
    /// step on screen by itself, so there is no scroll offset to track here: the focus engine
    /// is the scrollbar.
    fileprivate enum Field: Hashable {
        case strip
        /// The "fetching…" placeholder, which is a focus stop only while it is on screen.
        /// Without it, pressing down in the second before an article lands finds nothing to
        /// focus inside the panel and drops the user out into the video rows.
        case loading
        case step(Int)
    }

    @FocusState fileprivate var focus: Field?

    /// Whether the banner holds focus at all — the strip or any step of the article. What
    /// stops the ticker and what puts the panel on screen.
    private var isActive: Bool { focus != nil }

    /// Whether focus is down in the article rather than on the strip. Decides whether the
    /// article's opening is a focus stop — see the `isStop` argument in `reader`.
    private var isReading: Bool {
        if case .step = focus { return true }
        return false
    }

    /// Whether the strip will accept focus yet. False for the first moment it is on screen.
    ///
    /// tvOS gives initial focus to the topmost focusable view, and this strip is above
    /// everything — so Home would open with the ticker focused, which is to say stopped, and
    /// nothing would roll until the user pressed down. `prefersDefaultFocus(_:in:)` is the
    /// documented cure and does not win here (the strip is its own focus section, at the top of
    /// a scroll view). Staying unfocusable until the focus engine has settled on a card does,
    /// and costs nothing afterwards: enabling a view later doesn't pull focus to it.
    @State private var acceptsFocus = false

    /// True for the moment between Menu being pressed and the panel being gone.
    ///
    /// Menu can't simply hand focus to the feed: while the panel is open it has pushed the first
    /// shelf off the bottom of the screen, and a row that far outside a lazy stack isn't built,
    /// so there is no card there to focus — SwiftUI accepts the request and drops it. Taking
    /// every focusable in the banner away first forces focus out, which collapses the panel and
    /// brings the shelf back, and only then is there something for `onDismiss` to land on.
    @State private var isCollapsing = false

    /// The article body for the story on screen, in paragraphs. Empty while it is being fetched
    /// and for a page that has none to give.
    @State private var articleBody: [ArticleBlock] = []
    @State private var isLoadingArticle = false

    /// The picture-and-standfirst column beside the article text.
    private static let railWidth: CGFloat = 430

    /// The panel's height, fixed so that changing story doesn't shuffle the feed underneath.
    ///
    /// As much of the screen as there is, because every point of it is a line of story that
    /// doesn't have to be scrolled to. It stops just short of the bottom edge: the feed's scroll
    /// view is held still while reading (see `isFeedLocked`), but that lock lifts on the last
    /// block, and a panel jammed against the edge makes tvOS lurch the whole page at that
    /// moment to find margin for it.
    private static let panelHeight: CGFloat = 790

    /// The height the article gets to scroll in. Fixed rather than "whatever's left", so the
    /// reader is the same size on every story however long its paragraphs run.
    private static let readerHeight: CGFloat = 610

    /// Roughly how much text one press of down moves past — about three quarters of the reader,
    /// so a step leaves the last line or two of the previous block on screen to pick the thread
    /// back up from. By character count rather than measured height: blocks break on whole
    /// paragraphs anyway, so the real step is whatever fits under this.
    private static let charactersPerStep = 700

    /// Blank space after the last paragraph.
    ///
    /// The foot of the reader is busy: the text fades out over the bottom edge, and the
    /// end-of-story badge sits in the corner. Without room of its own the closing sentence ends
    /// up under both. Carried by the last step rather than by the scroll content, so that tvOS
    /// scrolling that step into view brings the whole gap with it — padding the container would
    /// make the space scrollable-to but not scrolled-to.
    private static let endInset: CGFloat = 92

    /// Identifier for the top of the article, so focus returning to the strip can rewind it.
    private static let readerTop = "reader-top"

    var body: some View {
        // The card takes real height rather than floating over the feed. Drawing it as an
        // overlay would keep the rows still, but it landed across the first shelf's heading and
        // cut it in half, which reads as a glitch. Pushing the feed down instead makes it a
        // drawer opening under the strip, and the rows slide back the moment focus leaves.
        VStack(spacing: 22) {
            strip
                .focusable(acceptsFocus && !isCollapsing)
                .focused($focus, equals: .strip)
                .onMoveCommand(perform: stepStory)
            if isActive, !isCollapsing, let item = focusedItem {
                storyPanel(item)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .focusEffectDisabled()
        // Menu, from the strip or from halfway down a story. Reading is a detour, and this is
        // the way back off it without walking to the end of the article first.
        .onExitCommand {
            isCollapsing = true
            onDismiss()
        }
        // Ends the collapse window. Held by the view rather than by a detached `Task`, so it is
        // cancelled if the banner goes away mid-collapse and restarted rather than duplicated if
        // Menu is pressed again — two overlapping timers could otherwise clear `isCollapsing`
        // out of order and make the strip focusable again while a collapse was still in flight.
        .task(id: isCollapsing) {
            guard isCollapsing else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            isCollapsing = false
        }
        .task {
            // One turn of the run loop after the feed has laid out is enough for the focus
            // engine to have picked its first card.
            try? await Task.sleep(for: .milliseconds(400))
            acceptsFocus = true
        }
        // Keyed to the story being read, so the fetch runs once per story and is cancelled the
        // moment the user steps past it — and never runs at all while the strip is rolling,
        // when `readingID` is nil and every frame would otherwise name a different article.
        .task(id: readingID) { await loadArticle() }
        .onChange(of: isFeedLocked, initial: true) { _, locked in onFeedLockChange(locked) }
        .onChange(of: isActive, initial: true) { _, active in onActiveChange(active) }
        .animation(.smooth(duration: 0.2), value: isAtEnd)
        .animation(.smooth(duration: 0.25), value: isActive)
        .onChange(of: isActive, initial: true) { _, focused in
            if focused {
                // Freeze where it actually is, not where the last pause left it.
                base = wrapped(distance(at: Date()))
                runStart = nil
                // Then tidy up: focus almost always lands mid-headline, and the chipped one
                // would be half off the left edge while the card below showed it in full.
                // Sliding it flush to the edge is what makes the two agree. Skipped before the
                // cells have been measured, when there is no such thing as a headline's start.
                let starts = cellStarts
                if laneWidth != nil, starts.indices.contains(index(at: base)) {
                    withAnimation(.smooth(duration: 0.3)) { base = starts[index(at: base)] }
                }
            } else {
                runStart = Date()
            }
        }
        // A refreshed feed is a different set of cells. Without clearing the old measurements
        // `cellWidths` keeps ids that are no longer in `items`, so its count never matches again
        // and `laneWidth` stays nil for good — which stops the marquee and disables stepping.
        .onChange(of: items.map(\.id)) { _, _ in
            cellWidths = [:]
            base = 0
            runStart = isActive ? nil : Date()
        }
        // Start the clock the moment the cells have been measured, not before. `distance` is
        // elapsed time times speed, so a run that began while the lap length was still unknown
        // would resolve into a large offset the instant it became known, and the strip would
        // open mid-jump.
        .onChange(of: laneWidth == nil) { _, unmeasured in
            if !unmeasured, !isActive { runStart = Date() }
        }
        .accessibilityLabel("News headlines")
        .accessibilityValue(focusedItem?.title ?? "")
    }

    // MARK: - Pieces

    /// The yellow strip itself: the pinned source badge, and the headlines rolling past it.
    private var strip: some View {
        HStack(spacing: 0) {
            badge
            marquee
        }
        .frame(height: Self.height)
        .background(Self.bannerYellow)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// The story the strip is stopped on, shown while the banner holds focus.
    ///
    /// The picture and the standfirst come from the feed; the text beside them is the article
    /// itself, fetched from the outlet's page — see `ArticleService`.
    private func storyPanel(_ item: NewsItem) -> some View {
        HStack(alignment: .top, spacing: 36) {
            VStack(alignment: .leading, spacing: 18) {
                AsyncImage(url: item.largeImageURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.07)
                }
                .frame(width: Self.railWidth, height: 242)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                if let publishedAt = item.publishedAt {
                    Text(publishedAt, format: .relative(presentation: .named))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Self.bannerYellow)
                }
                // The feed's standfirst, kept beside the article rather than in front of it:
                // it is the one-line version of what the columns say at length.
                Text(item.summary)
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(4)
                Spacer(minLength: 0)
            }
            .frame(width: Self.railWidth)

            VStack(alignment: .leading, spacing: 18) {
                Text(item.title)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
                    // Two lines' worth of space whether or not the headline needs both: without
                    // it a long page squeezes the headline to one truncated line, so turning the
                    // page moved the text under it.
                    .lineLimit(2, reservesSpace: true)
                reader
                    .frame(height: Self.readerHeight, alignment: .top)
                    // Only at the very end of the story, and drawn over the text rather than
                    // laid out below it: the warning is that the next press of down leaves, and
                    // a line that appears and reflows the article to say so would move the
                    // sentence being read at exactly the wrong moment.
                    .overlay(alignment: .bottomTrailing) {
                        if isAtEnd { endOfStory }
                    }
                    // Fades the text out at the top and bottom of the reader rather than
                    // slicing it: a scroll region almost always stops mid-line, and a hard cut
                    // through a row of letters reads as a rendering fault.
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 0.05),
                                .init(color: .black, location: 0.95),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(32)
        // Top-aligned, not centred: the default centres content inside a fixed frame, which
        // pushed the headline off the top as well as the tail off the bottom. Anything
        // over-long now runs off the bottom only, where it belongs.
        .frame(height: Self.panelHeight, alignment: .top)
        // Solid, not translucent: it sits directly above the feed's headings and cards, and
        // anything showing through turns the article into a mess to read.
        .background(Color(white: 0.07), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 2)
        }
        // A paragraph that runs past the bottom of a page is cut rather than allowed to push
        // the panel taller — the height is fixed so the feed below doesn't shuffle every time
        // the story changes.
        .clipped()
        .shadow(color: .black.opacity(0.7), radius: 26, y: 10)
    }

    /// The article, scrolled by walking down it a block at a time.
    ///
    /// Each block is a focus target, which is the whole mechanism: pressing down moves to the
    /// next block and tvOS scrolls it into view, so one press advances the story by about three
    /// quarters of a screen. No offset is tracked and no button press is intercepted — and
    /// stepping off the last block leaves for the feed on its own, because by then there is
    /// nothing below to focus but the feed.
    ///
    /// The text is drawn at one weight throughout, with no highlight on the focused block: the
    /// usual tvOS focus ring around a slab of prose reads as a button, and the scroll itself is
    /// the feedback that the press landed.
    @ViewBuilder
    private var reader: some View {
        if articleBody.isEmpty {
            Text(isLoadingArticle ? "Fetching the story…" : "The full story isn't available here.")
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.45))
                // Only while fetching: a story that genuinely has no body should let down carry
                // on to the feed rather than trapping focus on an apology.
                .modifier(StepFocus(focus: $focus, field: .loading, isStop: isLoadingArticle))
                .onMoveCommand(perform: stepStory)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 20) {
                        // Anchor for the scroll back to the top below.
                        Color.clear.frame(height: 0).id(Self.readerTop)
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            VStack(alignment: .leading, spacing: 20) {
                                ForEach(Array(step.enumerated()), id: \.offset) { _, block in
                                    switch block.kind {
                                    case .subheading:
                                        Text(block.text)
                                            .font(.system(size: 30, weight: .bold))
                                            .foregroundStyle(.white)
                                            .fixedSize(horizontal: false, vertical: true)
                                            // Extra air above, none below: a heading belongs to the
                                            // paragraphs after it, not the ones before.
                                            .padding(.top, 10)
                                    case .paragraph:
                                        Text(block.text)
                                            .font(.system(size: 28))
                                            .foregroundStyle(.white.opacity(0.85))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // Blank space under the closing sentence — see `endInset`. Inside the
                            // last step's own frame, so that tvOS scrolling that step into view
                            // brings the gap with it.
                            .padding(.bottom, index == steps.count - 1 ? Self.endInset : 0)
                            // The opening step is a stop only once the reader has focus.
                            //
                            // Coming *down* from the strip it must not be: it is already on
                            // screen, so focusing it would scroll nothing and the press would
                            // look swallowed. Coming back *up* it must be, or there is nothing
                            // above the second step to focus and up does nothing at all —
                            // leaving the start of the article unreachable.
                            .modifier(
                                StepFocus(
                                    focus: $focus,
                                    field: .step(index),
                                    isStop: index > 0 || isReading
                                )
                            )
                            .onMoveCommand(perform: stepStory)
                        }
                    }
                    // The top inset clears the fade below: at rest the reader is scrolled to the
                    // top, and without it the article's opening line sat inside the gradient and
                    // came up half-dimmed, as though it had already been scrolled past.
                    .padding(.top, 34)
                    .padding(.bottom, 6)
                }
                // Coming back up to the strip rewinds the article.
                //
                // Focus leaving the reader is not something the scroll view reacts to, so
                // without this it simply stayed where the last press of down left it: the strip
                // was focused again, the ticker was live again, and the opening paragraphs were
                // above the top of the panel with no way left to reach them — up had nowhere
                // further to go.
                .onChange(of: focus) { _, field in
                    guard field == .strip else { return }
                    withAnimation(.smooth(duration: 0.3)) {
                        proxy.scrollTo(Self.readerTop, anchor: .top)
                    }
                }
            }
        }
    }

    /// Shown across the foot of the reader once there is no more story: from here, down is the
    /// way out rather than the way on.
    private var endOfStory: some View {
        HStack(spacing: 12) {
            Image(systemName: "chevron.down")
            Text("End of story — down for videos")
        }
        .font(.system(size: 21, weight: .semibold))
        .foregroundStyle(.black)
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(Self.bannerYellow, in: Capsule())
        .padding(.bottom, 4)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// The article grouped into the steps that down moves through, whole paragraphs at a time.
    private var steps: [[ArticleBlock]] {
        var steps: [[ArticleBlock]] = []
        var current: [ArticleBlock] = []
        var length = 0
        for block in articleBody {
            if !current.isEmpty, length + block.text.count > Self.charactersPerStep {
                steps.append(current)
                current = []
                length = 0
            }
            current.append(block)
            length += block.text.count
        }
        if !current.isEmpty { steps.append(current) }
        return steps
    }

    /// True when focus is on the last step, so one more press of down leaves for the feed.
    private var isAtEnd: Bool {
        guard let last = steps.indices.last else { return false }
        return focus == .step(last)
    }

    private var badge: some View {
        Text(items.first?.source.displayName ?? "NEWS")
            .font(.system(size: 26, weight: .heavy, design: .rounded))
            .foregroundStyle(Self.bannerYellow)
            .padding(.horizontal, 28)
            .frame(maxHeight: .infinity)
            .background(.black)
    }

    private var marquee: some View {
        // Paused literally stops the clock: a frozen strip has nothing to redraw, and this is
        // pinned at the top of Home where it would otherwise tick over for the whole session.
        TimelineView(.animation(minimumInterval: nil, paused: runStart == nil)) { context in
            let shift = wrapped(distance(at: context.date))
            // The strip is far wider than the screen, and a view that wide would push the whole
            // banner off the right edge. Drawing it as an overlay on an empty box is what keeps
            // it out of the layout: the box takes the width it is offered, and the headlines
            // hanging off its right side are clipped rather than negotiated with.
            Color.clear
                .overlay(alignment: .leading) {
                    HStack(spacing: 0) {
                        lane(measuring: true)
                        // The stand-in that makes the wrap seamless. Not measured and not
                        // chipped — it is the same headlines a lap early.
                        lane(measuring: false)
                    }
                    // Without this the lanes are squeezed to the box's width and every headline
                    // truncates to an ellipsis.
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(x: -shift)
                }
                .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One full pass of the headlines. `measuring` marks the copy whose cell widths are the
    /// authoritative ones — both lanes are identical, so measuring both would be the same
    /// answer written twice.
    private func lane(measuring: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                cell(item, chipped: measuring && isActive && item.id == focusedItem?.id)
                    .modifier(WidthReader(enabled: measuring) { cellWidths[item.id] = $0 })
            }
        }
    }

    private func cell(_ item: NewsItem, chipped: Bool) -> some View {
        HStack(spacing: 26) {
            Text(item.title)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.black)
                .lineLimit(1)
                // Padding regardless of state: it is part of the cell's measured width, and a
                // chip that only pads itself when selected would lengthen the lap the moment
                // focus arrived and slide every other headline sideways.
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(chipped ? 1 : 0))
                        .shadow(color: .black.opacity(chipped ? 0.35 : 0), radius: 10, y: 3)
                }
            // The separator belongs to the headline before it, which is what makes the last
            // cell run into the first one of the next lap with the same gap as everywhere else.
            Circle()
                .fill(.black.opacity(0.4))
                .frame(width: 9, height: 9)
        }
        .padding(.horizontal, 26)
    }

    // MARK: - Article

    /// Whether the feed's own scroll view should be held still.
    ///
    /// Reading an article moves focus down through blocks that are already inside the panel, and
    /// tvOS answers that by scrolling *both* scroll views — so the ticker crept up under the
    /// clock and the whole page drifted while the story scrolled. Holding the outer one still
    /// leaves the inner one to do the work, which is the only thing that should move.
    ///
    /// Released on the last block, because that is where the user is about to leave: down from
    /// there has to reach the feed, and focus can't move to a row a locked scroll view won't
    /// bring on screen. An article with nothing to scroll never locks at all, for the same
    /// reason.
    private var isFeedLocked: Bool {
        guard isActive, !isCollapsing, steps.count > 1 else { return false }
        return !isAtEnd
    }

    /// The story whose text should be on screen — `nil` whenever the strip is rolling, which is
    /// what stops a fetch firing for every headline that drifts past the left edge.
    private var readingID: String? {
        isActive ? focusedItem?.id : nil
    }

    /// Fetches the article behind the story being read.
    ///
    /// Silent on failure: the panel falls back to the standfirst the feed gave it, which is a
    /// better answer on a TV than an error where the story should be.
    @MainActor
    private func loadArticle() async {
        articleBody = []
        guard let item = focusedItem, isActive else { return }

        isLoadingArticle = true
        let body = await ArticleService().body(for: item)
        isLoadingArticle = false
        // The user stepped on while this was in flight; that story's own fetch owns the panel.
        guard !Task.isCancelled, focusedItem?.id == item.id else { return }
        // Nothing came back — an index page, or a layout we no longer recognise. The feed's
        // one-line summary is what there is, so show that as the body.
        articleBody =
            body.isEmpty
            ? [item.summary].filter { !$0.isEmpty }.map { ArticleBlock(kind: .paragraph, text: $0) }
            : body
        // The placeholder that was holding focus has just been replaced by the article. Hand
        // focus to the first step of it, or back to the strip when there is nothing to scroll —
        // left alone, focus would be on a view that no longer exists and the engine would
        // resolve it to the feed.
        if focus == .loading { focus = steps.count > 1 ? .step(1) : .strip }
    }

    // MARK: - Motion

    /// One lap's length, or `nil` until every cell has been measured. Nothing moves before
    /// then: a partial sum would wrap the strip early and visibly.
    private var laneWidth: CGFloat? {
        guard !items.isEmpty, cellWidths.count == items.count else { return nil }
        let total = items.reduce(CGFloat.zero) { $0 + (cellWidths[$1.id] ?? 0) }
        return total > 0 ? total : nil
    }

    /// How far the strip has travelled at this instant — unbounded, so callers wrap it.
    ///
    /// Pinned to `base` until the cells have been measured: there is no lap to travel round yet,
    /// and counting time against one that doesn't exist is what would produce the jump the
    /// `laneWidth` observer above avoids.
    private func distance(at date: Date) -> CGFloat {
        guard let runStart, laneWidth != nil else { return base }
        return base + CGFloat(date.timeIntervalSince(runStart)) * Self.speed
    }

    /// A distance reduced to one lap, so the offset stays bounded however long the app runs.
    private func wrapped(_ distance: CGFloat) -> CGFloat {
        guard let laneWidth else { return 0 }
        let remainder = distance.truncatingRemainder(dividingBy: laneWidth)
        return remainder < 0 ? remainder + laneWidth : remainder
    }

    /// Where each headline starts within a lap, cumulative from the left.
    private var cellStarts: [CGFloat] {
        var starts: [CGFloat] = []
        var running: CGFloat = 0
        for item in items {
            starts.append(running)
            running += cellWidths[item.id] ?? 0
        }
        return starts
    }

    /// The headline currently at the left edge of the strip — the one the chip marks and the one
    /// the panel shows. Before the cells have been measured there is no such thing as a left
    /// edge, so this answers with the first headline rather than nothing: the panel opens on a
    /// real story either way, and the chip lands on it once the widths arrive.
    private var focusedItem: NewsItem? {
        guard laneWidth != nil else { return items.first }
        let position = wrapped(distance(at: Date()))
        return items.indices.contains(index(at: position)) ? items[index(at: position)] : items.first
    }

    /// Which headline spans this point in the lap — the last one that starts at or before it.
    private func index(at position: CGFloat) -> Int {
        cellStarts.lastIndex { $0 <= position } ?? 0
    }

    /// Left and right, wherever they are pressed inside the banner: another story.
    ///
    /// Attached to every focusable the banner has — the strip and each article step — rather
    /// than once to the whole thing. tvOS only counts a directional press as handled when the
    /// handler sits on the view that actually holds focus; on an ancestor it runs the action
    /// *and* moves focus anyway, which sent the user into the video rows on their first press of
    /// right.
    private func stepStory(_ direction: MoveCommandDirection) {
        switch direction {
        case .left: step(by: -1)
        case .right: step(by: 1)
        default: break
        }
    }

    /// Slides the strip to the neighbouring headline. The strip is frozen whenever this is
    /// reachable, so the position it starts from is the one the user is looking at.
    private func step(by delta: Int) {
        guard isActive, !items.isEmpty, laneWidth != nil else { return }
        // Back to the top of the new story, and out of the old story's steps — which are about
        // to be replaced by a different article's, and holding focus in one of them would leave
        // the reader scrolled to a paragraph that no longer exists. Only when it is needed:
        // re-requesting focus for the view that already has it makes SwiftUI resolve focus
        // afresh, and it resolves it to the feed.
        if focus != .strip { focus = .strip }
        let index = self.index(at: base)

        let target = (index + delta + items.count) % items.count
        let destination = cellStarts[target]
        // A step off either end is a jump across the whole lap. Animating that would send the
        // strip racing backwards past everything, which reads as a bug rather than a wrap.
        let wraps = (delta > 0 && target < index) || (delta < 0 && target > index)
        if wraps {
            base = destination
        } else {
            withAnimation(.smooth(duration: 0.3)) { base = destination }
        }
    }
}

/// Makes an article step a stop for the focus engine, or leaves it as plain text.
private struct StepFocus: ViewModifier {
    let focus: FocusState<NewsBanner.Field?>.Binding
    let field: NewsBanner.Field
    let isStop: Bool

    func body(content: Content) -> some View {
        if isStop {
            content.focusable().focused(focus, equals: field)
        } else {
            content
        }
    }
}

/// Reports a view's width, optionally. Wrapping this in a modifier rather than calling
/// `onGeometryChange` inline keeps the second, unmeasured lane from paying for geometry it
/// would only overwrite with the same numbers.
private struct WidthReader: ViewModifier {
    let enabled: Bool
    let onChange: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: onChange)
        } else {
            content
        }
    }
}
