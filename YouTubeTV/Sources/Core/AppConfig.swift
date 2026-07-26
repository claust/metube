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
        case visionOS  // playback stream extraction — HLS ladder up to 1080p60, needs visitorData
        case android  // playback fallback — muxed itag 18 only (360p)

        var name: String {
            switch self {
            case .tv: return "TVHTML5"
            case .visionOS: return "VISIONOS"
            case .android: return "ANDROID"
            }
        }
        var version: String {
            switch self {
            case .tv: return "7.20260707.07.00"
            case .visionOS: return "1.02"
            case .android: return "21.26.364"
            }
        }
        /// X-Youtube-Client-Name header value.
        var nameID: String {
            switch self {
            case .tv: return "7"
            case .visionOS: return "101"
            case .android: return "3"
            }
        }
        var userAgent: String {
            switch self {
            // These UA strings have to be reproduced verbatim; they can't be wrapped.
            // swiftlint:disable line_length
            case .tv:
                return
                    "Mozilla/5.0 (Linux armeabi-v7a; Android 7.1.2; Fire OS 6.0) Cobalt/22.lts.3.306369-gold (unlike Gecko) v8/8.8.278.8-jit gles Starboard/13, Amazon_ATV_mediatek8695_2019/NS6294 (Amazon, AFTMM, Wireless) com.amazon.firetv.youtube/22.3.r2.v66.0"
            case .visionOS:
                return
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
            // swiftlint:enable line_length
            case .android:
                return "com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip"
            }
        }
        var referer: String? {
            switch self {
            case .tv, .visionOS: return "https://www.youtube.com/tv"
            case .android: return nil
            }
        }
        /// Host used for youtubei/v1 calls.
        var host: String {
            switch self {
            case .tv, .visionOS: return "https://www.youtube.com"
            case .android: return "https://youtubei.googleapis.com"
            }
        }
        /// Whether `/player` needs a scraped `visitorData` to return streamingData.
        /// VISIONOS answers LOGIN_REQUIRED without one; ANDROID does not care.
        var requiresVisitorData: Bool {
            switch self {
            case .visionOS: return true
            case .tv, .android: return false
            }
        }
        /// Extra fields merged into context.client.
        var extraClientContext: [String: Any] {
            switch self {
            case .tv:
                return [:]
            case .visionOS:
                return [
                    "clientScreen": "WATCH",
                    "userAgent": userAgent,
                    "deviceMake": "Apple",
                    "deviceModel": "RealityDevice17,1",
                    "osName": "visionOS",
                    "osVersion": "26.5.23O471",
                ]
            case .android:
                return ["androidSdkVersion": 30, "osName": "Android", "osVersion": "11"]
            }
        }
    }

    /// Page scraped for `visitorData`. Served without auth; the SOCS cookie skips the
    /// EU consent interstitial, which otherwise replaces the player bootstrap JSON.
    static let visitorDataPageURL = URL(string: "https://www.youtube.com/tv?bpctr=9999999999&has_verified=1")!
}
