import Foundation

enum InnerTubeError: LocalizedError {
    case invalidURL
    case badResponse(Int)
    case notJSON
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Could not build a valid InnerTube request URL"
        case .badResponse(let code): return "InnerTube request failed (HTTP \(code))"
        case .notJSON: return "InnerTube response was not JSON"
        }
    }
}

/// Thin helper for youtubei/v1 POST calls. Builds the `context` and headers for a given
/// client, optionally attaching a Bearer token. Returns the parsed JSON dictionary.
enum InnerTubeClient {
    /// - Parameters:
    ///   - endpoint: e.g. "browse" or "player".
    ///   - client: which InnerTube client identity to use.
    ///   - params: endpoint params merged into the request body (e.g. ["browseId":"default"]).
    ///   - bearer: optional OAuth access token for authenticated calls.
    ///   - visitorData: optional session token, sent both in context.client and as
    ///     `X-Goog-Visitor-Id`. Required by some clients on `/player` — see `VisitorDataStore`.
    static func post(endpoint: String,
                     client: AppConfig.Client,
                     params: [String: Any],
                     bearer: String? = nil,
                     visitorData: String? = nil) async throws -> [String: Any] {
        let urlString = "\(client.host)/youtubei/v1/\(endpoint)?key=\(AppConfig.innerTubeAPIKey)&prettyPrint=false"
        guard let url = URL(string: urlString) else {
            throw InnerTubeError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.nameID, forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(client.version, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        if let referer = client.referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        if let visitorData {
            request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }

        var clientContext: [String: Any] = [
            "clientName": client.name,
            "clientVersion": client.version,
            "hl": "en",
            "gl": "US"
        ]
        for (k, v) in client.extraClientContext { clientContext[k] = v }
        if let visitorData { clientContext["visitorData"] = visitorData }

        var body: [String: Any] = ["context": ["client": clientContext]]
        for (k, v) in params { body[k] = v }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw InnerTubeError.badResponse(code)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InnerTubeError.notJSON
        }
        return json
    }
}

// MARK: - JSON traversal helpers (used by feed/player parsing)

extension Dictionary where Key == String, Value == Any {
    /// Follows a slash path like "playabilityStatus/status". Array indices not supported;
    /// use recursive search for that.
    func value(at path: String) -> Any? {
        var current: Any? = self
        for key in path.split(separator: "/") {
            guard let dict = current as? [String: Any] else { return nil }
            current = dict[String(key)]
        }
        return current
    }

    func string(at path: String) -> String? { value(at: path) as? String }
}

/// Recursively collect every dictionary that contains a key named `key` (the renderer name),
/// returning the value of that key. Useful for robustly locating all `tileRenderer` objects
/// regardless of the exact nesting.
func findAllRenderers(named key: String, in object: Any) -> [[String: Any]] {
    var results: [[String: Any]] = []
    func walk(_ obj: Any) {
        if let dict = obj as? [String: Any] {
            for (k, v) in dict {
                if k == key, let r = v as? [String: Any] {
                    results.append(r)
                }
                walk(v)
            }
        } else if let arr = obj as? [Any] {
            for v in arr { walk(v) }
        }
    }
    walk(object)
    return results
}

/// Extract the text from an InnerTube text object that may be {"simpleText":...} or {"runs":[{"text":...}]}.
func innerTubeText(_ obj: Any?) -> String? {
    guard let dict = obj as? [String: Any] else { return nil }
    if let s = dict["simpleText"] as? String { return s }
    if let runs = dict["runs"] as? [[String: Any]] {
        let text = runs.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? nil : text
    }
    return nil
}
