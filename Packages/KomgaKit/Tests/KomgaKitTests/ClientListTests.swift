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

    @Test("500 surfaces serverError")
    func serverError() async throws {
        let harness = try MockHarness()
        harness.stub { _ in .init(statusCode: 500) }
        await #expect(throws: KomgaError.serverError(status: 500)) {
            _ = try await harness.client.libraries()
        }
    }

    @Test("malformed body surfaces decoding error")
    func decodingError() async throws {
        let harness = try MockHarness()
        harness.stub { _ in .init(data: Data("not json".utf8)) }
        await #expect {
            _ = try await harness.client.libraries()
        } throws: { error in
            guard let error = error as? KomgaError, case .decoding = error else {
                return false
            }
            return true
        }
    }
}
