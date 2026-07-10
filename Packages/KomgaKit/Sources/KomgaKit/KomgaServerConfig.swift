import Foundation

/// Immutable connection configuration for a single Komga server.
///
/// Only `https` base URLs are accepted; the initializer throws
/// ``KomgaError/insecureURL`` for any other scheme so that insecure
/// connections are rejected at construction time.
public struct KomgaServerConfig: Sendable, Equatable {
    /// The server base URL. Guaranteed to use the `https` scheme.
    public let baseURL: URL
    /// The API key sent in the `X-API-Key` header of every request.
    public let apiKey: String

    /// Creates a configuration, validating that the base URL is secure.
    ///
    /// - Parameters:
    ///   - baseURL: The Komga server base URL. Must use `https`.
    ///   - apiKey: The API key for `X-API-Key` authentication.
    /// - Throws: ``KomgaError/insecureURL`` when `baseURL` is not `https`.
    public init(baseURL: URL, apiKey: String) throws {
        guard baseURL.scheme?.lowercased() == "https" else {
            throw KomgaError.insecureURL
        }
        self.baseURL = baseURL
        self.apiKey = apiKey
    }
}
