import SwiftUI

/// The personalized Home feed: a focusable grid of video thumbnails.
/// Selection is delegated to the orchestrator via `onSelectVideo`.
struct HomeView: View {
    /// Called when the user chooses a video. The orchestrator wires this to the player.
    var onSelectVideo: (VideoItem) -> Void

    @EnvironmentObject private var authStore: AuthStore

    @State private var items: [VideoItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 48), count: 4)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            content
        }
        .task {
            // Load once on first appear.
            if items.isEmpty && !isLoading {
                await load()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Loading your feed…")
                .font(.title2)
                .tint(.white)
                .foregroundStyle(.white)
        } else if let errorMessage {
            errorView(errorMessage)
        } else {
            feedGrid
        }
    }

    private var feedGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack {
                    Text("Home")
                        .font(.system(size: 56, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button("Sign out") { authStore.logout() }
                        .foregroundStyle(.white)
                }
                .padding(.top, 20)

                if items.isEmpty {
                    Text("No recommendations found.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .padding(.top, 40)
                } else {
                    LazyVGrid(columns: columns, spacing: 48) {
                        ForEach(items) { item in
                            VideoCard(item: item) { onSelectVideo(item) }
                        }
                    }
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 60)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 32) {
            Text("Couldn't load your feed")
                .font(.title)
                .foregroundStyle(.white)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await load() }
            }
            .font(.headline)
        }
        .padding(80)
    }

    private func load() async {
        guard let token = authStore.accessToken else {
            errorMessage = "You're not signed in."
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            items = try await FeedService().loadHome(accessToken: token)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A single focusable video thumbnail card.
private struct VideoCard: View {
    let item: VideoItem
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                AsyncImage(url: item.thumbnailURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .empty:
                        ZStack {
                            Color.gray.opacity(0.25)
                            ProgressView().tint(.white)
                        }
                    case .failure:
                        ZStack {
                            Color.gray.opacity(0.25)
                            Image(systemName: "play.rectangle")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                    @unknown default:
                        Color.gray.opacity(0.25)
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white, lineWidth: isFocused ? 4 : 0)
                )

                Text(item.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if !item.author.isEmpty {
                    Text(item.author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.08 : 1.0)
        .shadow(color: .black.opacity(isFocused ? 0.6 : 0), radius: 20)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}
