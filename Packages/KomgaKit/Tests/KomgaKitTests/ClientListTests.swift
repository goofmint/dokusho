import Foundation
import Testing

@testable import KomgaKit

@Suite("List APIs")
struct ClientListTests {
    @Test("currentUser hits /api/v2/users/me and decodes")
    func currentUser() async throws {
        let harness = try MockHarness()
        harness.stub { _ in .init(data: try Fixture.data("user")) }
        let user = try await harness.client.currentUser()
        #expect(user.email == "reader@example.com")
        let request = try #require(harness.lastRequest)
        #expect(request.url?.path == "/api/v2/users/me")
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == TestConfig.apiKey)
    }

    @Test("libraries hits /api/v1/libraries and decodes array")
    func libraries() async throws {
        let harness = try MockHarness()
        harness.stub { _ in .init(data: try Fixture.data("libraries")) }
        let libs = try await harness.client.libraries()
        #expect(libs.count == 2)
        #expect(harness.lastRequest?.url?.path == "/api/v1/libraries")
    }

    @Test("series sends library_id, search, page, size")
    func series() async throws {
        let harness = try MockHarness()
        harness.stub { _ in .init(data: try Fixture.data("series_page")) }
        let page = try await harness.client.series(
            libraryID: "0LIB0001", search: "yotsuba", page: 1, size: 30
        )
        #expect(page.content.count == 2)
        let request = try #require(harness.lastRequest)
        #expect(request.url?.path == "/api/v1/series")
        let query = queryDictionary(request)
        #expect(query["library_id"] == "0LIB0001")
        #expect(query["search"] == "yotsuba")
        #expect(query["page"] == "1")
        #expect(query["size"] == "30")
    }

    @Test("series omits nil/empty filters")
    func seriesNoFilters() async throws {
        let harness = try MockHarness()
        harness.stub { _ in .init(data: try Fixture.data("series_page")) }
        _ = try await harness.client.series(libraryID: nil, search: nil, page: 0, size: 20)
        let query = queryDictionary(try #require(harness.lastRequest))
        #expect(query["library_id"] == nil)
        #expect(query["search"] == nil)
        #expect(query["page"] == "0")
    }

    @Test("series full-text search posts Japanese query and library condition")
    func seriesFullTextSearch() async throws {
        let harness = try MockHarness()
        harness.stub { _ in .init(data: try Fixture.data("series_page")) }
        _ = try await harness.client.seriesSearch(
            libraryID: "0LIB0001", fullTextSearch: "ワンパン", page: 1, size: 30
        )
        let request = try #require(harness.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/v1/series/list")
        #expect(queryDictionary(request)["page"] == "1")
        #expect(queryDictionary(request)["size"] == "30")
        let body = try #require(listBodyData(request))
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["fullTextSearch"] as? String == "ワンパン")
        let condition = try #require(json["condition"] as? [String: Any])
        let library = try #require(condition["libraryId"] as? [String: Any])
        #expect(library["operator"] as? String == "is")
        #expect(library["value"] as? String == "0LIB0001")
    }

    @Test("series full-text search omits nil library condition")
    func seriesFullTextSearchWithoutLibrary() async throws {
        let harness = try MockHarness()
        harness.stub { _ in .init(data: try Fixture.data("series_page")) }
        _ = try await harness.client.seriesSearch(
            libraryID: nil, fullTextSearch: "ワンパン", page: 0, size: 20
        )
        let body = try #require(harness.lastRequest.flatMap(listBodyData))
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["condition"] == nil)
    }

    @Test("book full-text search posts Japanese query and series condition")
    func booksFullTextSearch() async throws {
        let harness = try MockHarness()
        harness.stub { _ in .init(data: try Fixture.data("books_page")) }
        _ = try await harness.client.booksSearch(
            seriesID: "0SERIES01", fullTextSearch: "ワンパン", page: 2, size: 10
        )
        let request = try #require(harness.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/v1/books/list")
        let body = try #require(listBodyData(request))
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["fullTextSearch"] as? String == "ワンパン")
        let condition = try #require(json["condition"] as? [String: Any])
        let series = try #require(condition["seriesId"] as? [String: Any])
        #expect(series["operator"] as? String == "is")
        #expect(series["value"] as? String == "0SERIES01")
    }

    @Test("books hits series/{id}/books")
    func books() async throws {
        let harness = try MockHarness()
        harness.stub { _ in .init(data: try Fixture.data("books_page")) }
        let page = try await harness.client.books(seriesID: "0SERIES01", page: 0, size: 20)
        #expect(page.content.count == 2)
        #expect(harness.lastRequest?.url?.path == "/api/v1/series/0SERIES01/books")
    }

    @Test("book hits books/{id}")
    func book() async throws {
        let harness = try MockHarness()
        harness.stub { _ in .init(data: try Fixture.data("book")) }
        let book = try await harness.client.book(id: "0BOOK0001")
        #expect(book.id == "0BOOK0001")
        #expect(harness.lastRequest?.url?.path == "/api/v1/books/0BOOK0001")
    }

    @Test("series by id hits series/{id}")
    func seriesByID() async throws {
        let harness = try MockHarness()
        harness.stub { _ in .init(data: try Fixture.data("series")) }
        let series = try await harness.client.series(id: "0SERIES01")
        #expect(series.id == "0SERIES01")
        #expect(harness.lastRequest?.url?.path == "/api/v1/series/0SERIES01")
    }
}

/// Reads a captured request body from either its data or stream representation.
private func listBodyData(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufferSize)
        if read <= 0 { break }
        data.append(buffer, count: read)
    }
    return data
}

@Suite("Error mapping via client")
struct ClientErrorTests {
    @Test("401 surfaces invalidAPIKey")
    func unauthorized() async throws {
        let harness = try MockHarness()
        harness.stub { _ in .init(statusCode: 401) }
        await #expect(throws: KomgaError.invalidAPIKey) {
            _ = try await harness.client.currentUser()
        }
    }

    @Test("404 surfaces notFound")
    func notFound() async throws {
        let harness = try MockHarness()
        harness.stub { _ in .init(statusCode: 404) }
        await #expect(throws: KomgaError.notFound) {
            _ = try await harness.client.book(id: "missing")
        }
    }

    @Test("400 surfaces clientError")
    func badRequest() async throws {
        let harness = try MockHarness()
        harness.stub { _ in .init(statusCode: 400) }
        await #expect(throws: KomgaError.clientError(status: 400)) {
            _ = try await harness.client.libraries()
        }
    }

    @Test("500 surfaces serverError")
    func serverError() async throws {
        let harness = try MockHarness()
        harness.stub { _ in .init(statusCode: 500) }
        await #expect(throws: KomgaError.serverError(status: 500)) {
            _ = try await harness.client.libraries()
        }
    }

    @Test("transient 502 on GET is retried and then succeeds")
    func transient502Retries() async throws {
        let harness = try MockHarness()
        let calls = Counter()
        harness.stub { _ in
            if calls.increment() == 1 {
                return .init(statusCode: 502)
            }
            return .init(data: try Fixture.data("libraries"))
        }
        let libraries = try await harness.client.libraries()
        #expect(libraries.count == 2)
        #expect(calls.value == 2)
    }

    @Test("persistent 502 on GET exhausts retries and throws")
    func persistent502Throws() async throws {
        let harness = try MockHarness()
        let calls = Counter()
        harness.stub { _ in
            _ = calls.increment()
            return .init(statusCode: 502)
        }
        await #expect(throws: KomgaError.serverError(status: 502)) {
            _ = try await harness.client.libraries()
        }
        #expect(calls.value == 3) // initial attempt + 2 retries
    }

    @Test("500 on GET is not retried (non-transient)")
    func nonTransient500NoRetry() async throws {
        let harness = try MockHarness()
        let calls = Counter()
        harness.stub { _ in
            _ = calls.increment()
            return .init(statusCode: 500)
        }
        await #expect(throws: KomgaError.serverError(status: 500)) {
            _ = try await harness.client.libraries()
        }
        #expect(calls.value == 1)
    }

    @Test("malformed body surfaces decoding error")
    func decodingError() async throws {
        let harness = try MockHarness()
        harness.stub { _ in .init(data: Data("not json".utf8)) }
        let thrown = await #expect(throws: KomgaError.self) {
            _ = try await harness.client.libraries()
        }
        guard case .decoding = try #require(thrown) else {
            Issue.record("expected KomgaError.decoding, got \(String(describing: thrown))")
            return
        }
    }
}
