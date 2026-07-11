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
    /// The base URL's path is normalized by stripping trailing slashes:
    /// `https://host/` and `https://host` are equivalent. Without this, path
    /// joining produces `https://host//api/...`, which Komga's security layer
    /// rejects as a non-normalized URL.
    ///
    /// - Parameters:
    ///   - baseURL: The Komga server base URL. Must use `https`.
    ///   - apiKey: The API key for `X-API-Key` authentication.
    /// - Throws: ``KomgaError/insecureURL`` when `baseURL` is not `https`
    ///   or cannot be normalized.
    public init(baseURL: URL, apiKey: String) throws {
        guard baseURL.scheme?.lowercased() == "https" else {
            throw KomgaError.insecureURL
        }
        self.baseURL = try Self.normalizing(baseURL)
        self.apiKey = apiKey
    }

    /// Strips trailing slashes from the URL's path component.
    private static func normalizing(_ url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw KomgaError.insecureURL
        }
        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        components.path = path
        guard let normalized = components.url else {
            throw KomgaError.insecureURL
        }
        return normalized
    }
}
