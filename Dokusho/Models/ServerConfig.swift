import Foundation
import SwiftData

/// The single registered Komga server.
///
/// Only one record ever exists (the app supports a single server per
/// design.md §0). The API key itself is **not** stored here — it lives in the
/// Keychain via ``CredentialStore``. This record holds only non-sensitive
/// connection metadata.
@Model
final class ServerConfig {
    /// Base URL of the Komga server. Always `https` (validated before save).
    var baseURL: URL
    /// Human-readable server name shown in the UI.
    var serverName: String
    /// When the connection was established/verified.
    var connectedAt: Date

    init(baseURL: URL, serverName: String, connectedAt: Date = .now) {
        self.baseURL = baseURL
        self.serverName = serverName
        self.connectedAt = connectedAt
    }
}
