import Foundation
import Testing

@testable import KomgaKit

enum Fixture {
    /// Loads a fixture JSON file bundled with the test target.
    static func data(_ name: String) throws -> Data {
        guard
            let url = Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        else {
            throw FixtureError.notFound(name)
        }
        return try Data(contentsOf: url)
    }

    enum FixtureError: Error, CustomStringConvertible {
        case notFound(String)
        var description: String {
            switch self {
            case let .notFound(name):
                return "Fixture not found: \(name).json"
            }
        }
    }
}

enum TestConfig {
    static let baseURL = URL(string: "https://komga.example.com")!
    static let apiKey = "test-api-key-123"

    static func make() throws -> KomgaServerConfig {
        try KomgaServerConfig(baseURL: baseURL, apiKey: apiKey)
    }
}

/// A self-contained mock harness: a unique session token, a `KomgaClient`
/// wired to a session that stamps that token, and helpers to install stubs and
/// inspect the captured request. Isolated per instance so tests running in
/// parallel never interfere.
final class MockHarness {
    let token: String
    let client: KomgaClient

    init() throws {
        let token = UUID().uuidString
        self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        config.httpAdditionalHeaders = [MockURLProtocol.sessionTokenHeader: token]
        let session = URLSession(configuration: config)
        client = KomgaClient(config: try TestConfig.make(), session: session)
    }

    func stub(_ handler: @escaping @Sendable (URLRequest) throws -> MockURLProtocol.Stub) {
        MockURLProtocol.setHandler(token: token, handler)
    }

    var lastRequest: URLRequest? {
        MockURLProtocol.lastRequest(token: token)
    }

    deinit {
        MockURLProtocol.reset(token: token)
    }
}

/// Parses the query items from a request URL into a dictionary.
/// Duplicate keys keep the first value; adequate for these tests.
func queryDictionary(_ request: URLRequest) -> [String: String] {
    guard
        let url = request.url,
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
        let items = components.queryItems
    else { return [:] }
    var result: [String: String] = [:]
    for item in items where result[item.name] == nil {
        result[item.name] = item.value
    }
    return result
}
