import Foundation
import Testing

@testable import KomgaKit

@Suite("Config & request foundation")
struct FoundationTests {
    @Test("https base URL is accepted")
    func acceptsHTTPS() throws {
        let config = try KomgaServerConfig(
            baseURL: URL(string: "https://komga.example.com")!,
            apiKey: "k"
        )
        #expect(config.baseURL.scheme == "https")
        #expect(config.apiKey == "k")
    }

    // A trailing-slash base produced https://host//api/... which Komga's
    // security layer rejects as non-normalized (surfaced as 400/502).
    @Test(
        "trailing-slash bases never produce double slashes",
        arguments: [
            ("https://komga.example.com/", "https://komga.example.com/api/v1/libraries"),
            ("https://komga.example.com", "https://komga.example.com/api/v1/libraries"),
            ("https://host.example/komga/", "https://host.example/komga/api/v1/libraries"),
            ("https://host.example/komga", "https://host.example/komga/api/v1/libraries"),
        ]
    )
    func normalizesTrailingSlash(base: String, expected: String) throws {
        let config = try KomgaServerConfig(
            baseURL: URL(string: base)!,
            apiKey: "k"
        )
        let builder = RequestBuilder(config: config)
        let request = try builder.makeRequest(path: "/api/v1/libraries")
        #expect(request.url?.absoluteString == expected)
    }

    @Test("http base URL is rejected as insecure")
    func rejectsHTTP() {
        #expect(throws: KomgaError.insecureURL) {
            _ = try KomgaServerConfig(
                baseURL: URL(string: "http://komga.example.com")!,
                apiKey: "k"
            )
        }
    }

    @Test("non-http scheme is rejected as insecure")
    func rejectsOtherScheme() {
        #expect(throws: KomgaError.insecureURL) {
            _ = try KomgaServerConfig(
                baseURL: URL(string: "ftp://komga.example.com")!,
                apiKey: "k"
            )
        }
    }

    @Test("every request carries the X-API-Key header")
    func requestHasAPIKeyHeader() throws {
        let builder = RequestBuilder(config: try TestConfig.make())
        let request = try builder.makeRequest(path: "/api/v1/libraries")
        #expect(
            request.value(forHTTPHeaderField: "X-API-Key") == TestConfig.apiKey
        )
    }

    @Test("request builds absolute URL under the base URL with query")
    func requestBuildsURL() throws {
        let builder = RequestBuilder(config: try TestConfig.make())
        let request = try builder.makeRequest(
            path: "/api/v1/series",
            queryItems: [
                URLQueryItem(name: "page", value: "0"),
                URLQueryItem(name: "size", value: "20"),
            ]
        )
        let url = try #require(request.url)
        #expect(url.absoluteString.hasPrefix("https://komga.example.com/api/v1/series"))
        let query = queryDictionary(request)
        #expect(query["page"] == "0")
        #expect(query["size"] == "20")
    }

    @Test("empty query values are dropped")
    func dropsEmptyQuery() throws {
        let builder = RequestBuilder(config: try TestConfig.make())
        let request = try builder.makeRequest(
            path: "/api/v1/series",
            queryItems: [URLQueryItem(name: "search", value: "")]
        )
        let url = try #require(request.url)
        #expect(url.query == nil)
    }

    @Test("PATCH body sets JSON content type")
    func patchBodySetsContentType() throws {
        let builder = RequestBuilder(config: try TestConfig.make())
        let request = try builder.makeRequest(
            method: "PATCH",
            path: "/api/v1/books/x/read-progress",
            body: Data("{}".utf8)
        )
        #expect(request.httpMethod == "PATCH")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.httpBody == Data("{}".utf8))
    }
}

@Suite("HTTP status → KomgaError mapping")
struct ErrorMappingTests {
    @Test("2xx maps to nil (no error)")
    func successMapsToNil() {
        #expect(KomgaError.fromStatus(200) == nil)
        #expect(KomgaError.fromStatus(204) == nil)
    }

    @Test("401 maps to invalidAPIKey")
    func unauthorized() {
        #expect(KomgaError.fromStatus(401) == .invalidAPIKey)
    }

    @Test("403 maps to forbidden")
    func forbidden() {
        #expect(KomgaError.fromStatus(403) == .forbidden)
    }

    @Test("404 maps to notFound")
    func notFound() {
        #expect(KomgaError.fromStatus(404) == .notFound)
    }

    @Test("5xx maps to serverError with status")
    func serverError() {
        #expect(KomgaError.fromStatus(500) == .serverError(status: 500))
        #expect(KomgaError.fromStatus(503) == .serverError(status: 503))
    }

    @Test("other 4xx maps to clientError with status")
    func clientError() {
        #expect(KomgaError.fromStatus(400) == .clientError(status: 400))
        #expect(KomgaError.fromStatus(418) == .clientError(status: 418))
    }

    @Test("3xx and out-of-range statuses map to unexpectedStatus")
    func unexpectedStatus() {
        #expect(KomgaError.fromStatus(302) == .unexpectedStatus(status: 302))
        #expect(KomgaError.fromStatus(600) == .unexpectedStatus(status: 600))
    }
}
