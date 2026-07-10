import SwiftUI
import SwiftData
import UIKit

/// Root view. Routes between the connection screen and the main UI based on
/// whether a usable connection exists.
///
/// On appear, if a `ServerConfig` is persisted it tries to restore the client
/// (loading the API key from the Keychain). If no config exists or the key is
/// missing, the connection screen is shown full-screen.
struct ContentView: View {
    @Environment(AppServices.self) private var services
    @Query private var serverConfigs: [ServerConfig]

    @State private var didAttemptRestore = false

    var body: some View {
        Group {
            if services.isConnected {
                MainView()
            } else {
                ConnectionView()
            }
        }
        .task {
            guard !didAttemptRestore else { return }
            didAttemptRestore = true
            restoreIfPossible()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.didReceiveMemoryWarningNotification
            )
        ) { _ in
            // Free in-memory cached images under memory pressure; disk is kept.
            if let loader = services.imageLoader {
                Task { await loader.purgeMemory() }
            }
        }
    }

    /// Attempts to restore a saved connection. A missing/failed key leaves the
    /// app disconnected (connection screen shown) rather than crashing.
    private func restoreIfPossible() {
        guard let config = serverConfigs.first else { return }
        do {
            try services.restore(from: config)
        } catch {
            // Restoration failed (e.g. Keychain error). Stay disconnected; the
            // user re-enters credentials on the connection screen.
            services.clearConnection()
        }
    }
}
