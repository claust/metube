import Foundation

/// Errors surfaced by the OAuth device-activation flow.
enum DeviceAuthError: LocalizedError {
    /// The server responded but the JSON could not be parsed / lacked required fields.
    case invalidResponse
    /// The device code expired (or the overall polling deadline was hit) before the
    /// user completed sign-in.
    case expired
    /// A terminal OAuth error was returned (e.g. `access_denied`, `invalid_grant`).
    case oauth(String)
    /// A non-OAuth transport / HTTP failure.
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The server sent an unexpected response. Please try again."
        case .expired:
            return "The sign-in code expired before you finished. Please try again."
        case .oauth(let code):
            switch code {
            case "access_denied":
                return "Sign-in was denied. Please try again."
            default:
                return "Sign-in failed (\(code)). Please try again."
            }
        case .http(let status):
            return "Network error (HTTP \(status)). Please try again."
        }
    }
}

/// Drives the YouTube-on-TV OAuth 2.0 device-activation flow:
/// request a user code, then poll the token endpoint until the user authorizes on
/// another device. See `reference/INNERTUBE.md` (Auth section) for the protocol.
actor DeviceAuthService {
    /// The user-facing activation code plus polling parameters.
    struct DeviceCode {
        let deviceCode: String
        let userCode: String
        let verificationURL: String
        let interval: Int
        let expiresIn: Int
    }

    /// The credentials returned once the user has authorized the device.
    struct Tokens {
        let accessToken: String
        let refreshToken: String?
    }

    /// Hard cap on total polling time, even if `expires_in` is larger.
    private static let maxPollSeconds = 300

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Step 1: request a device/user code

    func requestCode() async throws -> DeviceCode {
        let body = Self.formEncode([
            "client_id": AppConfig.oauthClientID,
            "scope": AppConfig.oauthScope,
        ])
        let json = try await postForm(url: AppConfig.deviceCodeURL, body: body)

        guard
            let deviceCode = json["device_code"] as? String,
            let userCode = json["user_code"] as? String,
            let verificationURL = json["verification_url"] as? String
        else {
            throw DeviceAuthError.invalidResponse
        }

        let interval = (json["interval"] as? Int) ?? 5
        let expiresIn = (json["expires_in"] as? Int) ?? Self.maxPollSeconds

        return DeviceCode(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: verificationURL,
            interval: max(1, interval),
            expiresIn: expiresIn
        )
    }

    // MARK: - Step 2: poll for tokens

    func poll(deviceCode: String, interval: Int) async throws -> Tokens {
        var currentInterval = max(1, interval)
        let deadline = Date().addingTimeInterval(TimeInterval(Self.maxPollSeconds))

        let body = Self.formEncode([
            "client_id": AppConfig.oauthClientID,
            "client_secret": AppConfig.oauthClientSecret,
            "code": deviceCode,
            "grant_type": AppConfig.deviceGrantType,
        ])

        while true {
            try Task.checkCancellation()

            // Wait one interval before (re)polling — the code isn't ready immediately.
            try await Task.sleep(nanoseconds: UInt64(currentInterval) * 1_000_000_000)
            try Task.checkCancellation()

            if Date() >= deadline {
                throw DeviceAuthError.expired
            }

            let json = try await postForm(url: AppConfig.tokenURL, body: body)

            if let accessToken = json["access_token"] as? String {
                let refreshToken = json["refresh_token"] as? String
                return Tokens(accessToken: accessToken, refreshToken: refreshToken)
            }

            if let error = json["error"] as? String {
                switch error {
                case "authorization_pending":
                    continue
                case "slow_down":
                    currentInterval += 5
                    continue
                case "expired_token":
                    throw DeviceAuthError.expired
                default:
                    throw DeviceAuthError.oauth(error)
                }
            }

            throw DeviceAuthError.invalidResponse
        }
    }

    // MARK: - Networking helpers

    /// POST an `application/x-www-form-urlencoded` body and return the parsed JSON object.
    /// OAuth errors are returned as JSON on 4xx responses, so those are parsed rather
    /// than thrown; only unexpected/non-JSON HTTP failures throw `.http`.
    private func postForm(url: URL, body: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw DeviceAuthError.invalidResponse
        }

        // Try to parse JSON regardless of status: the token endpoint returns
        // meaningful `{"error": ...}` payloads on 4xx.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }

        // No parseable JSON — treat non-2xx as a transport error.
        if !(200...299).contains(http.statusCode) {
            throw DeviceAuthError.http(http.statusCode)
        }
        throw DeviceAuthError.invalidResponse
    }

    /// RFC 3986 unreserved characters — everything else is percent-encoded.
    private static let unreservedCharacters = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Percent-encode form fields per `application/x-www-form-urlencoded`. Spaces are emitted
    /// as `+` per the form-encoding convention (a literal `+` is percent-encoded to `%2B` since
    /// it isn't in the unreserved set, so this replacement is unambiguous).
    private static func formEncode(_ fields: [String: String]) -> String {
        func encode(_ s: String) -> String {
            (s.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) ?? s)
                .replacingOccurrences(of: "%20", with: "+")
        }
        return fields
            .map { key, value in "\(encode(key))=\(encode(value))" }
            .joined(separator: "&")
    }
}
