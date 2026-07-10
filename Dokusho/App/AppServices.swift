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

    /// Whether the app currently has a usable connection (config + client).
    var isConnected: Bool { client != nil }

    init(credentialStore: CredentialStore = CredentialStore()) {
        self.credentialStore = credentialStore
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
            return
        }
        let serverConfig = try KomgaServerConfig(baseURL: config.baseURL, apiKey: apiKey)
        let newClient = KomgaClient(config: serverConfig)
        client = newClient
        imageLoader = PageImageLoader(client: newClient)
    }

    /// Activates a verified client after a successful connection.
    func setConnected(client: KomgaClient) {
        self.client = client
        imageLoader = PageImageLoader(client: client)
    }

    /// Clears the in-memory client (used on disconnect). Persisted state is
    /// removed by the caller.
    func clearConnection() {
        client = nil
        imageLoader = nil
    }
}
