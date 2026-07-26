import Foundation

extension AuthStore {
    /// Runs an InnerTube request with the current access token, refreshing it once on a
    /// 401/403 and retrying. Returns `nil` when the work was cancelled or the refresh failed
    /// (which signs the user out — `refresh()` clears the tokens and RootView returns to Login),
    /// so callers can tell "nothing to show, and nothing to report" from a real error.
    func authorized<T>(_ request: (String) async throws -> T) async throws -> T? {
        guard let token = accessToken else { return nil }
        do {
            return try await request(token)
        } catch {
            // The view was dismissed while loading — not a real error.
            if isCancellation(error) { return nil }
            guard isAuthError(error) else { throw error }
            guard await refresh(), let newToken = accessToken else {
                return nil  // logged out — the router will show Login
            }
            return try await request(newToken)
        }
    }
}

/// An expired/invalid access token surfaces as a 401/403 from InnerTube.
func isAuthError(_ error: Error) -> Bool {
    guard let inner = error as? InnerTubeError, case .badResponse(let code) = inner else {
        return false
    }
    return code == 401 || code == 403
}
