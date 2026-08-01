import Foundation

enum AppwriteError: LocalizedError {
    case notConfigured
    case badResponse(Int, String?)
    case notJSON
    /// The session is gone or was never valid — the caller should re-authenticate rather than
    /// retry, which is the one failure worth distinguishing.
    case unauthorized(String?)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "No Appwrite endpoint is configured"
        case .badResponse(let code, let message):
            return message.map { "Appwrite: \($0) (HTTP \(code))" } ?? "Appwrite request failed (HTTP \(code))"
        case .notJSON: return "Appwrite response was not JSON"
        case .unauthorized(let message):
            return message.map { "Appwrite rejected the session: \($0)" } ?? "Appwrite rejected the session"
        }
    }
}

/// Thin client for the handful of Appwrite endpoints the watch-progress sync needs, in the
/// same shape as `InnerTubeClient`.
///
/// Hand-rolled rather than `appwrite/sdk-for-apple`, which pulls in AsyncHTTPClient and
/// SwiftNIO — a large dependency tree for four REST calls, in an app that otherwise has none.
/// Paths and headers are taken from that SDK's source (v18.3.0, server 1.9.x).
struct AppwriteClient {
    /// A session, as the app needs to remember it.
    ///
    /// Appwrite hands sessions out as a cookie — `Session.secret` in the response body is
    /// empty, whatever the platform (verified against 1.9.6), so this stores the `a_session_*`
    /// pair and replays it. The SDK does the same thing, only implicitly.
    /// `userId` rides along because rows are written with permissions for it.
    struct Session: Codable, Hashable {
        let userId: String
        let cookie: String
    }

    let endpoint: URL
    let projectID: String
    /// Present once the profile has a session; `nil` while only the auth function can be called.
    var session: Session?

    private let urlSession: URLSession

    init?(session: Session? = nil, urlSession: URLSession = .shared) {
        guard let endpoint = AppConfig.appwriteEndpoint, !AppConfig.appwriteProjectID.isEmpty else {
            return nil
        }
        self.endpoint = endpoint
        self.projectID = AppConfig.appwriteProjectID
        self.session = session
        self.urlSession = urlSession
    }

    // MARK: - Auth

    /// Trades a YouTube access token for an Appwrite session, via the `metube-auth` function.
    ///
    /// Two round trips: the function proves who the token belongs to and mints a custom token,
    /// then that token is exchanged for the session. See `Backend/README.md`.
    func signIn(accessToken: String, accountKey: String) async throws -> Session {
        let execution = try await call(
            method: "POST",
            path: "/functions/\(AppConfig.appwriteAuthFunctionID)/executions",
            body: [
                "body": encodeJSON(["accessToken": accessToken, "accountKey": accountKey]),
                "path": "/",
                "method": "POST",
            ]
        )

        // The function's own response is a string inside the execution — its status code is
        // reported separately from the execution's, which is 200 as long as it ran at all.
        let status = execution["responseStatusCode"] as? Int ?? 0
        let payload = decodeJSON(execution["responseBody"] as? String) ?? [:]
        guard (200..<300).contains(status) else {
            throw AppwriteError.badResponse(status, payload["message"] as? String)
        }
        guard let userId = payload["userId"] as? String, let secret = payload["secret"] as? String else {
            throw AppwriteError.notJSON
        }

        let (_, response) = try await send(
            method: "POST",
            path: "/account/sessions/token",
            body: ["userId": userId, "secret": secret]
        )
        guard let cookie = Self.sessionCookie(from: response) else { throw AppwriteError.notJSON }
        return Session(userId: userId, cookie: cookie)
    }

    /// The `a_session_*` cookies from a sign-in response, as a `Cookie` header value.
    ///
    /// Parsed through `HTTPCookie` rather than by reading the header: Foundation folds repeated
    /// `Set-Cookie` headers into one comma-joined string, and cookie values contain commas.
    private static func sessionCookie(from response: URLResponse) -> String? {
        guard let http = response as? HTTPURLResponse, let url = http.url else { return nil }
        // Rebuilt key by key rather than cast: `allHeaderFields` is `[AnyHashable: Any]`, and a
        // whole-dictionary `as? [String: String]` is all-or-nothing — one non-string entry and
        // sign-in silently stops working.
        var fields: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { continue }
            fields[key] = value
        }
        let pairs = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            .filter { $0.name.hasPrefix("a_session_") }
            .map { "\($0.name)=\($0.value)" }
        return pairs.isEmpty ? nil : pairs.joined(separator: "; ")
    }

    // MARK: - Rows

    /// One page of rows. `total` is not requested — the sync pages until a short page comes
    /// back, and counting rows costs the server an extra query.
    func listRows(
        databaseID: String,
        tableID: String,
        queries: [String]
    ) async throws -> [[String: Any]] {
        let json = try await call(
            method: "GET",
            path: "/tablesdb/\(databaseID)/tables/\(tableID)/rows",
            query: queries.map { URLQueryItem(name: "queries[]", value: $0) }
                + [URLQueryItem(name: "total", value: "false")]
        )
        return json["rows"] as? [[String: Any]] ?? []
    }

    /// Creates or replaces a row. Row ids are derived, not generated, so this is the only write
    /// the sync needs — no read-before-write, and a repeated push is harmless.
    func upsertRow(
        databaseID: String,
        tableID: String,
        rowID: String,
        data: [String: Any],
        permissions: [String]
    ) async throws {
        _ = try await call(
            method: "PUT",
            path: "/tablesdb/\(databaseID)/tables/\(tableID)/rows/\(rowID)",
            body: ["data": data, "permissions": permissions]
        )
    }

    // MARK: - Transport

    private func call(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        try await send(method: method, path: path, query: query, body: body).json
    }

    private func send(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: [String: Any]? = nil
    ) async throws -> (json: [String: Any], response: URLResponse) {
        guard var components = URLComponents(url: endpoint.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        else { throw AppwriteError.notConfigured }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw AppwriteError.notConfigured }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(projectID, forHTTPHeaderField: "X-Appwrite-Project")
        request.setValue("1.9.5", forHTTPHeaderField: "X-Appwrite-Response-Format")
        // Appwrite matches this against the platforms registered on the project; without a
        // matching tvOS platform every call is refused. The SDK sends exactly this.
        request.setValue("appwrite-tvos://\(AppConfig.bundleID)", forHTTPHeaderField: "Origin")
        // Sent by hand rather than left to `HTTPCookieStorage`, which this app shares with
        // every YouTube request and which does not survive a reinstall — the one moment the
        // whole feature exists for.
        request.httpShouldHandleCookies = false
        if let session {
            request.setValue(session.cookie, forHTTPHeaderField: "Cookie")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await urlSession.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        // Parsed regardless of status: Appwrite puts its own explanation in the error body,
        // which is a great deal more useful than the status code alone.
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(code) else {
            if code == 401 { throw AppwriteError.unauthorized(json?["message"] as? String) }
            throw AppwriteError.badResponse(code, json?["message"] as? String)
        }
        guard let json else { throw AppwriteError.notJSON }
        return (json, response)
    }

    private func encodeJSON(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func decodeJSON(_ string: String?) -> [String: Any]? {
        guard let data = string?.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

// MARK: - Queries

/// The query strings Appwrite expects in `queries[]`, built by hand for the two the sync uses.
/// The SDK's `Query` helper is a thin JSON encoder over the same shape.
enum AppwriteQuery {
    static func equal(_ attribute: String, _ value: String) -> String {
        encode(method: "equal", attribute: attribute, values: [value])
    }

    static func greaterThan(_ attribute: String, _ value: String) -> String {
        encode(method: "greaterThan", attribute: attribute, values: [value])
    }

    static func orderAsc(_ attribute: String) -> String {
        encode(method: "orderAsc", attribute: attribute, values: nil)
    }

    static func limit(_ value: Int) -> String {
        encode(method: "limit", attribute: nil, values: [value])
    }

    static func cursorAfter(_ rowID: String) -> String {
        encode(method: "cursorAfter", attribute: nil, values: [rowID])
    }

    private static func encode(method: String, attribute: String?, values: [Any]?) -> String {
        var object: [String: Any] = ["method": method]
        if let attribute { object["attribute"] = attribute }
        if let values { object["values"] = values }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
