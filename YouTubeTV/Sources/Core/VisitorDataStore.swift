import Foundation

/// Fetches and caches the `visitorData` token that the VISIONOS client needs on `/player`.
///
/// Without it that client answers `LOGIN_REQUIRED` and returns no `streamingData` at all;
/// with it (and nothing else — no PO token, no signatureTimestamp) it returns the full
/// adaptive ladder plus an `hlsManifestUrl`. The token is a plain string scraped out of the
/// YouTube-on-TV page bootstrap and is not tied to a user account.
actor VisitorDataStore {
    static let shared = VisitorDataStore()

    /// Tokens stay valid far longer than this; refetching hourly just bounds staleness
    /// without making every playback pay for a page load.
    private static let ttl: TimeInterval = 60 * 60

    private var cached: String?
    private var fetchedAt: Date?
    /// In-flight fetch, so simultaneous playbacks share one request instead of racing.
    private var inFlight: Task<String, Error>?

    /// Returns a cached token when fresh, otherwise scrapes a new one.
    func token() async throws -> String {
        if let cached, let fetchedAt, Date().timeIntervalSince(fetchedAt) < Self.ttl {
            return cached
        }
        if let inFlight { return try await inFlight.value }

        let task = Task { try await Self.scrape() }
        inFlight = task
        defer { inFlight = nil }

        let token = try await task.value
        cached = token
        fetchedAt = Date()
        return token
    }

    /// Drops the cached token so the next call refetches. Called when a request that used it
    /// still came back unauthorized, which is what an expired token looks like.
    func invalidate() {
        cached = nil
        fetchedAt = nil
    }

    // MARK: - Scraping

    private static func scrape() async throws -> String {
        var request = URLRequest(url: AppConfig.visitorDataPageURL)
        request.setValue(AppConfig.Client.tv.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")
        request.setValue("SOCS=CAE=", forHTTPHeaderField: "Cookie")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw VisitorDataError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw VisitorDataError.notFound
        }
        guard let token = extractVisitorData(from: html) else {
            throw VisitorDataError.notFound
        }
        return token
    }

    /// Pulls the value out of `"visitorData":"..."` in the page bootstrap. The embedded value is
    /// JSON-escaped (it routinely contains `=` padding), so it is unescaped by decoding it
    /// as a JSON string rather than by hand.
    static func extractVisitorData(from html: String) -> String? {
        guard let range = html.range(of: #""visitorData":"[^"]*""#, options: .regularExpression) else {
            return nil
        }
        // Drop the `"visitorData":` prefix, leaving a complete JSON string literal.
        let literal = html[range].dropFirst(#""visitorData":"#.count)
        guard let data = literal.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data),
              !decoded.isEmpty else {
            return nil
        }
        return decoded
    }
}

enum VisitorDataError: LocalizedError {
    case badResponse(Int)
    case notFound

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): return "Could not reach YouTube to start a session (HTTP \(code))"
        case .notFound: return "Could not start a YouTube session"
        }
    }
}
