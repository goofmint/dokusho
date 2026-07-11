import Foundation

/// A `URLProtocol` that intercepts requests and responds with a
/// per-session stub handler, capturing that session's last request.
///
/// Swift Testing runs suites in parallel, so a single global handler would be
/// clobbered across concurrently-running tests. State is therefore keyed by a
/// unique session token (carried in a request header) so each test's session
/// is fully isolated.
final class MockURLProtocol: URLProtocol {
    /// A canned response for a single request.
    struct Stub {
        let statusCode: Int
        let data: Data?
        let headers: [String: String]

        init(statusCode: Int = 200, data: Data? = nil, headers: [String: String] = [:]) {
            self.statusCode = statusCode
            self.data = data
            self.headers = headers
        }
    }

    /// Header used to route a request to its owning session's stub.
    static let sessionTokenHeader = "X-Mock-Session"

    private struct Entry {
        var handler: (@Sendable (URLRequest) throws -> Stub)?
        var lastRequest: URLRequest?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [String: Entry] = [:]

    /// Registers a stub handler for a session token, clearing prior state.
    static func setHandler(
        token: String,
        _ handler: @escaping @Sendable (URLRequest) throws -> Stub
    ) {
        lock.lock()
        defer { lock.unlock() }
        entries[token] = Entry(handler: handler, lastRequest: nil)
    }

    /// Removes all state for a session token.
    static func reset(token: String) {
        lock.lock()
        defer { lock.unlock() }
        entries[token] = nil
    }

    /// The most recent request handled for a session token.
    static func lastRequest(token: String) -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return entries[token]?.lastRequest
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let token = request.value(forHTTPHeaderField: MockURLProtocol.sessionTokenHeader) ?? ""

        MockURLProtocol.lock.lock()
        MockURLProtocol.entries[token]?.lastRequest = request
        let handler = MockURLProtocol.entries[token]?.handler
        MockURLProtocol.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let stub = try handler(request)
            guard
                let url = request.url,
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: stub.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: stub.headers
                )
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data = stub.data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
