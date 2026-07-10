import Foundation

/// Builds `URLRequest`s for the Komga API, centralizing base-URL resolution
/// and `X-API-Key` header injection so no call site can omit authentication.
struct RequestBuilder: Sendable {
    /// Header name used by Komga for API-key authentication.
    static let apiKeyHeader = "X-API-Key"

    private let baseURL: URL
    private let apiKey: String

    init(config: KomgaServerConfig) {
        baseURL = config.baseURL
        apiKey = config.apiKey
    }

    /// Builds a request for the given path and query items.
    ///
    /// - Parameters:
    ///   - method: The HTTP method. Defaults to `GET`.
    ///   - path: The API path, e.g. `/api/v1/libraries`.
    ///   - queryItems: Query items to append. Empty items are ignored.
    ///   - body: An optional request body (already-encoded JSON).
    ///   - accept: The `Accept` header value. Defaults to JSON; image and
    ///     file endpoints must override this — sending `application/json`
    ///     there makes Komga's content negotiation answer 406.
    /// - Returns: A fully-formed request with the API key header set.
    /// - Throws: ``KomgaError/insecureURL`` if the resolved URL is malformed.
    func makeRequest(
        method: String = "GET",
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        accept: String = "application/json"
    ) throws -> URLRequest {
        let url = try resolve(path: path, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: Self.apiKeyHeader)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Resolves an absolute URL for a path against the base URL, appending
    /// non-empty query items.
    private func resolve(path: String, queryItems: [URLQueryItem]) throws -> URL {
        guard
            var components = URLComponents(
                url: baseURL.appendingPathComponent(path),
                resolvingAgainstBaseURL: false
            )
        else {
            throw KomgaError.insecureURL
        }
        let filtered = queryItems.filter { item in
            guard let value = item.value else { return false }
            return !value.isEmpty
        }
        if !filtered.isEmpty {
            components.queryItems = filtered
        }
        guard let url = components.url else {
            throw KomgaError.insecureURL
        }
        return url
    }
}
