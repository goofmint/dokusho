import UIKit

/// Minimal app delegate.
///
/// Its only job is to receive the background `URLSession` completion handler so
/// downloads that finish while the app is suspended can be flushed, and hand it
/// to the ``DownloadManager``.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// The app's download manager, injected by ``DokushoApp`` once the
    /// dependency container is built. The system may deliver a background
    /// completion event before this is set (e.g. immediately on cold launch),
    /// so we buffer any pending handler until the manager arrives.
    @MainActor
    weak var downloadManager: DownloadManager? {
        didSet { flushPendingBackgroundEvents() }
    }

    /// Buffered background-session events that arrived before the
    /// ``downloadManager`` was wired up. Each is `(identifier, completionHandler)`.
    @MainActor
    private var pendingBackgroundEvents: [(String, () -> Void)] = []

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // This delegate method is called on the main thread.
        MainActor.assumeIsolated {
            if let manager = downloadManager {
                manager.handleBackgroundEvents(identifier: identifier, completionHandler: completionHandler)
            } else {
                pendingBackgroundEvents.append((identifier, completionHandler))
            }
        }
    }

    @MainActor
    private func flushPendingBackgroundEvents() {
        guard let manager = downloadManager, !pendingBackgroundEvents.isEmpty else { return }
        let events = pendingBackgroundEvents
        pendingBackgroundEvents.removeAll()
        for (identifier, handler) in events {
            manager.handleBackgroundEvents(identifier: identifier, completionHandler: handler)
        }
    }
}
