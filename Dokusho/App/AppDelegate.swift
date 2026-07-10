import UIKit

/// Minimal app delegate.
///
/// Its only current job is to receive the background `URLSession` completion
/// handler so downloads that finish while the app is suspended can be flushed.
/// The `DownloadManager` (Phase 6) will store and invoke the handler; for now
/// we only capture it.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Completion handler handed to us by the system when a background
    /// URLSession finishes its events. Phase 6 stores this on the
    /// `DownloadManager` keyed by `identifier` and calls it once the matching
    /// session drains its delegate queue.
    var backgroundSessionCompletionHandler: (() -> Void)?

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // Phase 6 will route this by `identifier` to the DownloadManager.
        backgroundSessionCompletionHandler = completionHandler
    }
}
