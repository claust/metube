import SwiftUI
import UIKit

/// A remote image, and the cache behind it.
///
/// Stands in for `AsyncImage`, which the app used everywhere until it turned out not to survive
/// the way a TV app is actually used. Two things about it are wrong here:
///
///  * **A cancelled load is a permanent failure.** `AsyncImage` reports cancellation as
///    `.failure` and never tries again for as long as the view lives, so anything that tears an
///    image's load down mid-flight — the screen saver coming up, a spell in another app, Home
///    swapping in a refreshed page — leaves that card showing its fallback for good. It was
///    always the cards *on screen* that broke, because those are the ones with a load in flight
///    when it happens; cards scrolled in afterwards are new views that start clean, which is why
///    the row looked fine again a few tiles along.
///  * **Nothing is remembered across a rebuild.** Every rebuilt view starts its own download,
///    so a row of cards from one channel fetched the same avatar once per card.
///
/// This keeps decoded images in memory, coalesces concurrent requests for the same URL, retries
/// a genuine failure a few times, and treats cancellation as "not loaded yet" — the next
/// appearance simply asks again.
struct RemoteImage<Content: View>: View {
    let url: URL?
    @ViewBuilder let content: (RemoteImagePhase) -> Content

    @Environment(\.scenePhase) private var scenePhase
    @State private var phase: RemoteImagePhase
    /// Which URL `phase` is holding an image of. A view can outlive the URL it was given — the
    /// news panel stays mounted while the strip steps from story to story — and state persists
    /// across that, so "already loaded" has to mean *this* image and not merely some image.
    @State private var loadedURL: URL?

    init(url: URL?, @ViewBuilder content: @escaping (RemoteImagePhase) -> Content) {
        self.url = url
        self.content = content
        // Straight from the cache where there's a hit, so a card that is rebuilt — scrolled back
        // to, or redrawn under a refreshed page — draws its artwork in the first frame instead of
        // blinking through a placeholder on its way back to the image it already had.
        let cached = url.flatMap(ImageCache.shared.cached(for:))
        _phase = State(initialValue: cached.map(RemoteImagePhase.loaded) ?? .loading)
        _loadedURL = State(initialValue: cached == nil ? nil : url)
    }

    var body: some View {
        content(phase)
            // Cancelled when the view goes away, which leaves `phase` on `.loading` rather than
            // on a failure: coming back runs this again and asks for the image afresh.
            //
            // Keyed on the scene phase as well as the URL, so that returning to the foreground
            // restarts the load. A load killed by the app going to the background gets no fresh
            // appearance to retry on — the views are still there, still mounted, still holding
            // whatever they ended up with — and on a TV the screen saver alone is enough to
            // background the app and tear down every image still in flight.
            //
            // The retry belongs on this modifier rather than in an `onChange` firing a `Task` of
            // its own: an unstructured task there outlives the view that made it, and one still
            // running when the URL changed would land its result — the previous picture — on
            // state the new URL had already settled, with nothing left to correct it.
            .task(id: Reload(url: url, scenePhase: scenePhase)) { await load() }
    }

    /// What a load is keyed on: change either and the load starts over.
    private struct Reload: Equatable {
        let url: URL?
        let scenePhase: ScenePhase
    }

    /// Asks the cache for the image, unless this view already has that exact one.
    ///
    /// Stated rather than inferred: the closure `.task` takes is `@Sendable` and carries no
    /// isolation of its own, and everything below here writes view state.
    @MainActor
    private func load() async {
        guard let url else {
            phase = .loading
            loadedURL = nil
            return
        }
        if loadedURL == url, case .loaded = phase { return }
        // A different URL than the one on screen: whatever is showing is now the wrong picture,
        // so it goes before the new one is asked for. From the cache in the same breath where
        // there is a hit, so stepping back to a story already seen doesn't blink.
        if loadedURL != url {
            loadedURL = nil
            if let cached = ImageCache.shared.cached(for: url) {
                phase = .loaded(cached)
                loadedURL = url
                return
            }
            phase = .loading
        }
        do {
            phase = .loaded(Image(uiImage: try await ImageCache.shared.image(for: url)))
            loadedURL = url
        } catch {
            // A cancelled load leaves the phase alone. Nothing was learned about the image, only
            // that nobody was waiting for it at that moment — and `.failed` is a verdict this
            // view would then never revisit.
            guard !isCancellation(error) else { return }
            phase = .failed
        }
    }
}

/// What a `RemoteImage` has to draw with.
///
/// `.loading` is also where a cancelled load leaves things — a load that was interrupted has no
/// verdict on the image, and will be tried again.
enum RemoteImagePhase {
    case loading
    case loaded(Image)
    case failed

    /// The image, once there is one.
    var image: Image? {
        if case .loaded(let image) = self { return image }
        return nil
    }
}

/// Fetches images, once each.
///
/// Requests for a URL already in flight join the one that is running rather than starting a
/// second: a row of cards from one channel asks for that channel's avatar once, not once a card.
/// The fetch itself is unstructured on purpose — it belongs to the cache rather than to whichever
/// view happened to ask first, so that view going away doesn't cancel a download every other card
/// on screen is still waiting for.
actor ImageCache {
    static let shared = ImageCache()

    /// Decoded images, held by the URL they came from. Backed by `NSCache`, so the system can
    /// take the memory back under pressure — `URLCache` still has the bytes on disk, and a
    /// re-decode is cheap next to another round trip.
    private let memory = MemoryImageCache()

    /// Fetches in progress, so concurrent askers share one request.
    private var inFlight: [URL: Task<UIImage, Error>] = [:]

    /// How many times a failing URL is tried before the caller is told it failed. Thumbnails are
    /// served by a CDN that occasionally refuses a request under a burst; asking again a moment
    /// later almost always works.
    private static let attempts = 3

    /// Between attempts, doubling. Short enough to land while the card is still on screen.
    private static let retryDelay = Duration.milliseconds(400)

    /// The image at `url`, from memory if it is there and from the network otherwise.
    func image(for url: URL) async throws -> UIImage {
        if let image = memory.image(for: url) { return image }

        let task: Task<UIImage, Error>
        if let running = inFlight[url] {
            task = running
        } else {
            // Unstructured, which is what keeps the download alive independently of whoever asked
            // for it: an unstructured task is not a child of the task that made it and does not
            // inherit its cancellation, so a card scrolling away mid-download leaves the fetch
            // running for the cards still waiting on it. Awaiting `value` below doesn't propagate
            // the waiter's cancellation either — it only rethrows what the download itself threw.
            task = Task { try await Self.download(url) }
            inFlight[url] = task
        }

        do {
            let image = try await task.value
            inFlight[url] = nil
            memory.insert(image, for: url)
            return image
        } catch {
            // Cleared on every outcome, cancellation included. A task that ended is not one a
            // later caller can join — leaving it here would hand everyone who asks afterwards the
            // same stale failure for good, which is the shape of bug this whole type exists to
            // put right.
            inFlight[url] = nil
            throw error
        }
    }

    /// Whatever is already in memory for `url`, without going near the network. Lets a view being
    /// rebuilt draw its image in the same frame — see `RemoteImage.init`.
    nonisolated func cached(for url: URL) -> Image? {
        memory.image(for: url).map(Image.init(uiImage:))
    }

    private static func download(_ url: URL) async throws -> UIImage {
        var delay = retryDelay
        for attempt in 1...attempts {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
                else {
                    throw URLError(.badServerResponse)
                }
                guard let image = UIImage(data: data) else {
                    throw URLError(.cannotDecodeContentData)
                }
                return image
            } catch {
                // Torn down rather than refused — the app went to the background, most likely.
                // Not a failure of the image, and not worth retrying from in here: nothing will
                // succeed until the app is back, and coming back is itself a retry.
                if isCancellation(error) { throw error }
                guard attempt < attempts else { throw error }
                try await Task.sleep(for: delay)
                delay *= 2
            }
        }
        throw URLError(.cannotLoadFromNetwork)
    }
}

/// The `NSCache` behind `ImageCache`, wrapped so the actor can read it from outside its own
/// isolation — `NSCache` is thread-safe, which is the whole reason the synchronous cache peek in
/// `RemoteImage.init` is allowed to exist.
private final class MemoryImageCache: @unchecked Sendable {
    private let cache = NSCache<NSURL, UIImage>()

    init() {
        // A screenful of tvOS artwork at 1280×720 is a few tens of MB decoded; this holds a good
        // deal more than that, so scrolling a row back and forth never re-fetches.
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    func image(for url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    func insert(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL, cost: image.decodedByteCount)
    }
}

extension UIImage {
    /// Roughly what this image occupies decoded, for the cache's cost accounting.
    fileprivate var decodedByteCount: Int {
        guard let cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
