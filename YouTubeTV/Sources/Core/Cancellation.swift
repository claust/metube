import Foundation

/// Whether a thrown error is just this work being cancelled rather than a real failure.
///
/// Checking `Task.isCancelled` alone isn't enough: `URLSession` reports a cancelled request as
/// `URLError.cancelled` (-999), and that can surface after the request was torn down without the
/// enclosing task itself being marked cancelled — which would otherwise show the user an error
/// for a screen they already dismissed.
func isCancellation(_ error: Error) -> Bool {
    if Task.isCancelled || error is CancellationError { return true }
    return (error as? URLError)?.code == .cancelled
}
