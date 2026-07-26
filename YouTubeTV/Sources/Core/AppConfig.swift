import Foundation

/// Static configuration for the YouTube InnerTube / OAuth device flow.
/// Values verified against live requests on 2026-07-26 (see reference/INNERTUBE.md).
enum AppConfig {
    /// Reads a value injected into Info.plist from `Config/Secrets.xcconfig` at build time.
    /// Returns "" when the key is absent (e.g. the xcconfig wasn't set up) so the app still
    /// builds; API calls then fail at runtime — typically a 4xx from YouTube surfaced as an
    /// `InnerTubeError.badResponse`. See `Config/Secrets.example.xcconfig`.
    private static func secret(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
    }

    /// Public InnerTube web API key (used for all clients). Not confidential, but kept in the
    /// gitignored xcconfig alongside the OAuth values so all credentials live in one place.
    static var innerTubeAPIKey: String { secret("YTInnerTubeAPIKey") }

    // MARK: OAuth device flow (YouTube-on-TV credentials)
    static var oauthClientID: String { secret("YTOAuthClientID") }
    static var oauthClientSecret: String { secret("YTOAuthClientSecret") }
    static let oauthScope = "http://gdata.youtube.com https://www.googleapis.com/auth/youtube-paid-content"
    static let deviceCodeURL = URL(string: "https://www.youtube.com/o/oauth2/device/code")!
    static let tokenURL = URL(string: "https://www.youtube.com/o/oauth2/token")!
    static let deviceGrantType = "http://oauth.net/grant_type/device/1.0"

    // MARK: InnerTube clients
    enum Client {
        case tv  // personalized feeds — needs Bearer token
        case android  // playback stream extraction — works unauthenticated

        var name: String {
            switch self {
            case .tv: return "TVHTML5"
            case .android: return "ANDROID"
            }
        }
        var version: String {
            switch self {
            case .tv: return "7.20260707.07.00"
            case .android: return "21.26.364"
            }
        }
        /// X-Youtube-Client-Name header value.
        var nameID: String {
            switch self {
            case .tv: return "7"
            case .android: return "3"
            }
        }
        var userAgent: String {
            switch self {
            case .tv:
                // The TV client's UA has to be reproduced verbatim; it can't be wrapped.
                // swiftlint:disable line_length
                return
                    "Mozilla/5.0 (Linux armeabi-v7a; Android 7.1.2; Fire OS 6.0) Cobalt/22.lts.3.306369-gold (unlike Gecko) v8/8.8.278.8-jit gles Starboard/13, Amazon_ATV_mediatek8695_2019/NS6294 (Amazon, AFTMM, Wireless) com.amazon.firetv.youtube/22.3.r2.v66.0"
            // swiftlint:enable line_length
            case .android:
                return "com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip"
            }
        }
        var referer: String? {
            switch self {
            case .tv: return "https://www.youtube.com/tv"
            case .android: return nil
            }
        }
        /// Host used for youtubei/v1 calls.
        var host: String {
            switch self {
            case .tv: return "https://www.youtube.com"
            case .android: return "https://youtubei.googleapis.com"
            }
        }
        /// Extra fields merged into context.client.
        var extraClientContext: [String: Any] {
            switch self {
            case .tv:
                return [:]
            case .android:
                return ["androidSdkVersion": 30, "osName": "Android", "osVersion": "11"]
            }
        }
    }
}
