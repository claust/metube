import Foundation
import SwiftUI

/// Search: a tvOS search field over a grid of matching videos.
/// Selection is delegated to the orchestrator via `onSelectVideo`, exactly as `HomeView` does.
struct SearchView: View {
    /// Called when the user chooses a result. The orchestrator wires this to the player.
    var onSelectVideo: (VideoItem) -> Void

    @EnvironmentObject private var authStore: AuthStore

    @State private var query = ""
    @State private var results: [VideoItem] = []
    @State private var isSearching = false
    @State private var errorMessage: String?

    /// The query the current `results` belong to, so the empty state can name it and a
    /// stale "no results" doesn't linger under a query that hasn't run yet.
    @State private var searchedQuery = ""

    /// tvOS typing is one focus-move per character, so a live search would fire a request
    /// for nearly every letter. Waiting this long after the last keystroke collapses a
    /// word into one request while still feeling immediate.
    private static let debounce = Duration.milliseconds(500)

    /// Below this, results are dominated by noise and the request isn't worth making.
    private static let minimumQueryLength = 2

    /// Accessibility identifier on each result card. Shared with `SearchUITests`.
    static let resultIdentifier = "SearchResult"

    private static let columns = [GridItem(.adaptive(minimum: Metrics.cardWidth), spacing: Metrics.cardSpacing)]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            content
        }
        .searchable(text: $query, prompt: "Search YouTube")
        // Re-runs whenever `query` changes, cancelling the in-flight run first — which is
        // what makes the sleep below a debounce rather than a fixed delay on every keystroke.
        .task(id: query) {
            await searchAfterDebounce()
        }
    }

    @ViewBuilder
    private var content: some View {
        if isSearching {
            ProgressView("Searching…")
                .font(.title2)
                .tint(.white)
                .foregroundStyle(.white)
        } else if let errorMessage {
            errorView(errorMessage)
        } else if results.isEmpty {
            emptyState
        } else {
            resultsGrid
        }
    }

    private var resultsGrid: some View {
        ScrollView(.vertical) {
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: Metrics.cardSpacing) {
                ForEach(results) { item in
                    VideoCard(item: item) { onSelectVideo(item) }
                        // The tvOS keyboard is made of buttons too, so a UI test needs a
                        // way to count result cards specifically.
                        .accessibilityIdentifier(Self.resultIdentifier)
                }
            }
            .padding(.horizontal, Metrics.horizontalInset)
            // Room for the focused card to grow without being clipped at the edges.
            .padding(.vertical, 40)
        }
        .scrollClipDisabled()
    }

    @ViewBuilder
    private var emptyState: some View {
        // Distinguish "nothing typed yet" from "we ran this and it found nothing" — the
        // second is a result, and saying so stops it reading as a stuck screen.
        if searchedQuery.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 80))
                    .foregroundStyle(.secondary)
                Text("Search for videos")
                    .font(.title2)
                    .foregroundStyle(.white)
            }
        } else {
            Text("No results for “\(searchedQuery)”.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 32) {
            Text("Search failed")
                .font(.title)
                .foregroundStyle(.white)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await runSearch(trimmedQuery) }
            }
            .font(.headline)
        }
        .padding(80)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Waits out the debounce, then searches — unless a newer keystroke cancelled this task.
    @MainActor
    private func searchAfterDebounce() async {
        let text = trimmedQuery
        guard text.count >= Self.minimumQueryLength else {
            // Clearing the field returns to the prompt rather than leaving the previous
            // query's results behind, which would look like the search ignored the edit.
            results = []
            searchedQuery = ""
            errorMessage = nil
            return
        }

        // Cancelled by the next keystroke: leave the previous results on screen and let
        // the newer task take over. Only the last one in a burst gets past this.
        guard (try? await Task.sleep(for: Self.debounce)) != nil else { return }

        await runSearch(text)
    }

    @MainActor
    private func runSearch(_ text: String) async {
        guard !text.isEmpty else { return }
        guard authStore.accessToken != nil else {
            errorMessage = "You're not signed in."
            return
        }

        isSearching = true
        errorMessage = nil
        defer { isSearching = false }

        do {
            guard
                let items = try await authStore.authorized({ token in
                    try await SearchService().search(query: text, accessToken: token)
                })
            else {
                return  // cancelled or signed out — nothing to show and nothing to report
            }
            results = items
            searchedQuery = text
        } catch {
            if isCancellation(error) { return }
            errorMessage = error.localizedDescription
        }
    }
}
