import Foundation
import Testing

@testable import KomgaKit

/// Uses a decoder matching the client's date strategy so fixtures decode
/// the same way they would from the live client.
private func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let fallback = ISO8601DateFormatter()
    fallback.formatOptions = [.withInternetDateTime]
    decoder.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        if let date = formatter.date(from: string) { return date }
        if let date = fallback.date(from: string) { return date }
        throw DecodingError.dataCorruptedError(
            in: container, debugDescription: "bad date \(string)"
        )
    }
    return decoder
}

@Suite("DTO decoding")
struct DTODecodingTests {
    let decoder = makeDecoder()

    @Test("KomgaUser decodes")
    func decodeUser() throws {
        let user = try decoder.decode(KomgaUser.self, from: Fixture.data("user"))
        #expect(user.id == "0ABCUSER01")
        #expect(user.email == "reader@example.com")
        #expect(user.roles.contains("FILE_DOWNLOAD"))
    }

    @Test("Library array decodes, including unavailable flag")
    func decodeLibraries() throws {
        let libs = try decoder.decode([KomgaLibrary].self, from: Fixture.data("libraries"))
        #expect(libs.count == 2)
        #expect(libs[0].name == "Manga")
        #expect(libs[0].unavailable == false)
        #expect(libs[1].unavailable == true)
    }

    @Test("Series page decodes with reading direction")
    func decodeSeriesPage() throws {
        let page = try decoder.decode(
            Page<KomgaSeries>.self, from: Fixture.data("series_page")
        )
        #expect(page.content.count == 2)
        #expect(page.totalElements == 42)
        #expect(page.totalPages == 3)
        #expect(page.number == 0)
        #expect(page.first == true)
        #expect(page.last == false)

        let first = page.content[0]
        #expect(first.name == "Yotsuba&!")
        #expect(first.metadata.readingDirection == .rightToLeft)
        #expect(first.metadata.readingDirectionRaw == "RIGHT_TO_LEFT")
        #expect(first.booksInProgressCount == 1)

        let second = page.content[1]
        #expect(second.metadata.readingDirection == .leftToRight)
    }

    @Test("Book decodes with media profile, page count, and read progress")
    func decodeBook() throws {
        let book = try decoder.decode(KomgaBook.self, from: Fixture.data("book"))
        #expect(book.id == "0BOOK0001")
        #expect(book.media.mediaProfile == "PDF")
        #expect(book.media.pagesCount == 180)
        #expect(book.metadata.authors.count == 2)
        #expect(book.metadata.authors.first?.name == "Kiyohiko Azuma")
        let progress = try #require(book.readProgress)
        #expect(progress.page == 42)
        #expect(progress.completed == false)
        #expect(book.sizeBytes == 104_857_600)
    }

    @Test("Book round-trips through Codable for offline persistence")
    func encodeDecodeBookRoundTrip() throws {
        let original = try decoder.decode(KomgaBook.self, from: Fixture.data("book"))

        // The offline persistence layer uses matching `.iso8601` strategies on a
        // plain encoder/decoder pair, so mirror that here.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let roundTripDecoder = JSONDecoder()
        roundTripDecoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(original)
        let restored = try roundTripDecoder.decode(KomgaBook.self, from: data)
        #expect(restored == original)
    }

    @Test("Book without read progress decodes readProgress as nil")
    func decodeBooksPageMixedProgress() throws {
        let page = try decoder.decode(
            Page<KomgaBook>.self, from: Fixture.data("books_page")
        )
        #expect(page.content.count == 2)
        #expect(page.content[0].readProgress != nil)
        #expect(page.content[1].readProgress == nil)
        #expect(page.content[1].media.mediaProfile == "EPUB")
    }

    @Test("Page list decodes with optional dimensions")
    func decodePages() throws {
        let pages = try decoder.decode([KomgaPage].self, from: Fixture.data("pages"))
        #expect(pages.count == 2)
        #expect(pages[0].number == 1)
        #expect(pages[0].width == 1200)
        #expect(pages[0].height == 1800)
        #expect(pages[1].width == nil)
        #expect(pages[1].mediaType == "image/webp")
    }

    @Test("Collections page decodes")
    func decodeCollections() throws {
        let page = try decoder.decode(
            Page<KomgaCollection>.self, from: Fixture.data("collections_page")
        )
        let collection = try #require(page.content.first)
        #expect(collection.name == "Best of 2024")
        #expect(collection.ordered == true)
        #expect(collection.seriesIds == ["0SERIES01", "0SERIES02"])
    }

    @Test("Read lists page decodes")
    func decodeReadLists() throws {
        let page = try decoder.decode(
            Page<KomgaReadList>.self, from: Fixture.data("readlists_page")
        )
        let list = try #require(page.content.first)
        #expect(list.name == "Crossover Event")
        #expect(list.bookIds == ["0BOOK0001", "0BOOK0002"])
        #expect(list.summary == "Reading order for the crossover.")
    }

    @Test("Unknown reading direction is preserved")
    func unknownReadingDirection() {
        let direction = KomgaReadingDirection(rawValue: "DIAGONAL")
        #expect(direction == .unknown("DIAGONAL"))
    }
}
