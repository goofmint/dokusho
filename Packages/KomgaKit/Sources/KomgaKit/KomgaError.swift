import Foundation

/// Errors surfaced by ``KomgaClient``.
///
/// HTTP responses are normalized into these cases so that callers can present
/// consistent, user-facing messaging without inspecting raw status codes.
public enum KomgaError: Error, Sendable {
    /// HTTP 401. The API key is missing, expired, or invalid.
    case invalidAPIKey
    /// HTTP 403. The API key is valid but lacks permission for the resource.
    case forbidden
    /// HTTP 404. The requested resource does not exist (possibly deleted).
    case notFound
    /// HTTP 5xx. A server-side error occurred; retrying may succeed.
    case serverError(status: Int)
    /// A transport-level failure (offline, timeout, TLS, cancellation).
    case network(URLError)
    /// The response body could not be decoded into the expected type.
    case decoding(Error)
    /// The provided base URL is not `https`. Rejected at configuration time.
    case insecureURL
}

extension KomgaError {
    /// Maps an HTTP status code to a ``KomgaError`` for non-2xx responses.
    ///
    /// - Parameter status: The HTTP status code from the response.
    /// - Returns: The mapped error, or `nil` when the status is a 2xx success.
    static func fromStatus(_ status: Int) -> KomgaError? {
        switch status {
        case 200...299:
            return nil
        case 401:
            return .invalidAPIKey
        case 403:
            return .forbidden
        case 404:
            return .notFound
        case 500...599:
            return .serverError(status: status)
        default:
            // Treat any other unexpected non-2xx status as a server error so
            // the failure is surfaced rather than silently ignored.
            return .serverError(status: status)
        }
    }
}

extension KomgaError: Equatable {
    public static func == (lhs: KomgaError, rhs: KomgaError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidAPIKey, .invalidAPIKey),
            (.forbidden, .forbidden),
            (.notFound, .notFound),
            (.insecureURL, .insecureURL):
            return true
        case let (.serverError(l), .serverError(r)):
            return l == r
        case let (.network(l), .network(r)):
            return l.code == r.code
        case (.decoding, .decoding):
            // Underlying decoding errors are not Equatable; matching on the
            // case is sufficient for test assertions.
            return true
        default:
            return false
        }
    }
}
