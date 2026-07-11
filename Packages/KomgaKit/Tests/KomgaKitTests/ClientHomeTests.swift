import Foundation
import Testing

@testable import KomgaKit

@Suite("Home / collections / read lists")
struct ClientHomeTests {
    @Test("keepReading sends read_status and sort")
    func keepReading() async throws {
        let harness = try MockHarness()
        harness.stub { _ in .init(data: try Fixture.data("books_page")) }
        _ = try await harness.client.keepReading(page: 0, size: 20)
        let request = try #require(harness.lastRequest)
        #expect(request.url?.path == "/api/v1/books")
        let query = queryDictionary(request)
        #expect(query["read_status"] == "IN_PROGRESS")
        #expect(query["sort"] == "readProgress.readDate,desc")
    }

    @Test("onDeck hits books/ondeck")
    func onDeck() async throws {
        let harness = try MockHarness()
        harness.stub { _ in .init(data: try Fixture.data("books_page")) }
        let page = try await harness.client.onDeck(page: 0, size: 20)
        #expect(page.content.count == 2)
        #expect(harness.lastRequest?.url?.path == "/api/v1/books/ondeck")
    }

    @Test("collections hits /api/v1/collections and decodes")
    func collections() async throws {
        let harness = try MockHarness()
        harness.stub { _ in .init(data: try Fixture.data("collections_page")) }
        let page = try await harness.client.collections(page: 0, size: 20)
        #expect(page.content.first?.name == "Best of 2024")
        #expect(harness.lastRequest?.url?.path == "/api/v1/collections")
    }

    @Test("collectionSeries hits collections/{id}/series")
    func collectionSeries() async throws {
        let harness = try MockHarness()
        harness.stub { _ in .init(data: try Fixture.data("series_page")) }
        let page = try await harness.client.collectionSeries(id: "0COLL0001", page: 0, size: 20)
        #expect(page.content.count == 2)
        #expect(harness.lastRequest?.url?.path == "/api/v1/collections/0COLL0001/series")
    }

    @Test("readLists hits /api/v1/readlists and decodes")
    func readLists() async throws {
        let harness = try MockHarness()
        harness.stub { _ in .init(data: try Fixture.data("readlists_page")) }
        let page = try await harness.client.readLists(page: 0, size: 20)
        #expect(page.content.first?.name == "Crossover Event")
        #expect(harness.lastRequest?.url?.path == "/api/v1/readlists")
    }

    @Test("readListBooks hits readlists/{id}/books")
    func readListBooks() async throws {
        let harness = try MockHarness()
        harness.stub { _ in .init(data: try Fixture.data("books_page")) }
        let page = try await harness.client.readListBooks(id: "0READ0001", page: 0, size: 20)
        #expect(page.content.count == 2)
        #expect(harness.lastRequest?.url?.path == "/api/v1/readlists/0READ0001/books")
    }
}
