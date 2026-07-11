import Foundation
import Observation
import SwiftData
import KomgaKit

/// Top-level dependency container, injected through the SwiftUI environment.
///
/// Holds app-wide services and the derived connection state. Views observe this
/// to decide whether to show the connection screen or the main UI. Kept on the
/// main actor because it drives UI state.
@MainActor
@Observable
final class AppServices {
    /// Keychain-backed API key storage.
    let credentialStore: CredentialStore

    /// The active Komga API client, or `nil` when not connected.
    ///
    /// Set on successful connection (or on launch when a config + key already
    /// exist), cleared on disconnect.
    private(set) var client: KomgaClient?

    /// The shared page/thumbnail image loader, valid while connected.
    ///
    /// Recreated whenever the client changes (connect/disconnect) so it always
    /// builds requests with the current credentials. `nil` when not connected.
    private(set) var imageLoader: PageImageLoader?

    /// Book file download manager, valid while connected. Recreated with the
    /// client so background requests always carry current credentials.
    private(set) var downloadManager: DownloadManager?

    /// Read-progress syncer, valid while connected. Recreated with the client so
    /// it PATCHes progress with current credentials; flushes its offline queue on
    /// connect and on network restore.
    private(set) var progressSyncer: ReadProgressSyncer?

    /// Shared SwiftData context used by services that persist state.
    private let modelContext: ModelContext

    /// Whether the app currently has a usable connection (config + client).
    var isConnected: Bool { client != nil }

    init(credentialStore: CredentialStore = CredentialStore(), modelContext: ModelContext) {
        self.credentialStore = credentialStore
        self.modelContext = modelContext
    }

    /// Attempts to restore a client from a previously saved config + Keychain key.
    ///
    /// Called on launch with the persisted `ServerConfig` (if any). If the key
    /// is missing, the app stays disconnected and the connection screen shows —
    /// no fallback, no silent guess.
    func restore(from config: ServerConfig) throws {
        guard let apiKey = try credentialStore.loadAPIKey() else {
            client = nil
            imageLoader = nil
            downloadManager = nil
            progressSyncer = nil
            return
        }
        let serverConfig = try KomgaServerConfig(baseURL: config.baseURL, apiKey: apiKey)
        let newClient = KomgaClient(config: serverConfig)
        client = newClient
        activate(client: newClient)
    }

    /// Activates a verified client after a successful connection.
    func setConnected(client: KomgaClient) {
        self.client = client
        activate(client: client)
    }

    /// Builds and installs the per-client services (image loader, download
    /// manager, progress syncer) in a single place, so `restore` and
    /// `setConnected` stay in lockstep. The `client` property is assigned by the
    /// caller before this runs.
    private func activate(client: KomgaClient) {
        imageLoader = makeImageLoader(client: client)
        downloadManager = DownloadManager(client: client, modelContext: modelContext)
        activateProgressSyncer(client: client)
    }

    /// Builds the page/thumbnail loader with the user's persisted cache-limit
    /// setting applied to the page disk cache.
    private func makeImageLoader(client: KomgaClient) -> PageImageLoader {
        PageImageLoader(client: client, diskLimit: CacheLimit.currentBytes())
    }

    /// Applies a changed cache-limit setting to the live loader without dropping
    /// the in-memory caches. Safe to call while disconnected (no-op).
    func applyCacheLimit(_ bytes: Int) {
        guard let imageLoader else { return }
        Task { await imageLoader.updateDiskLimit(bytes) }
    }

    /// Clears the in-memory client (used on disconnect). Persisted state is
    /// removed by the caller.
    func clearConnection() {
        client = nil
        imageLoader = nil
        downloadManager = nil
        progressSyncer = nil
    }

    /// Builds the syncer for the given client and flushes any queued progress
    /// left over from a previous (possibly offline) session.
    private func activateProgressSyncer(client: KomgaClient) {
        let syncer = ReadProgressSyncer(client: client, modelContext: modelContext)
        progressSyncer = syncer
        Task { await syncer.flushPending() }
    }
}
