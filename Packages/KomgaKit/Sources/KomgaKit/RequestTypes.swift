import Foundation

/// An on-the-fly image format conversion requested from Komga for a page image.
///
/// Passed as the `convert` query parameter on `GET /books/{id}/pages/{n}`.
public enum ImageConversion: String, Sendable {
    case jpeg
    case png
}

/// Identifies a resource whose thumbnail is being requested.
///
/// Maps to `GET /api/v1/{books|series|collections|readlists}/{id}/thumbnail`.
public enum ThumbnailTarget: Sendable, Equatable {
    case book(id: String)
    case series(id: String)
    case collection(id: String)
    case readList(id: String)

    /// The API path (relative to the base URL) for this thumbnail.
    var path: String {
        switch self {
        case let .book(id):
            return "/api/v1/books/\(id)/thumbnail"
        case let .series(id):
            return "/api/v1/series/\(id)/thumbnail"
        case let .collection(id):
            return "/api/v1/collections/\(id)/thumbnail"
        case let .readList(id):
            return "/api/v1/readlists/\(id)/thumbnail"
        }
    }
}

// MARK: - Search requests

/// Encodes Komga's equality operator with its discriminator and value.
struct SearchEqualityDto: Encodable {
    let value: String

    private enum CodingKeys: String, CodingKey {
        case `operator`, value
    }

    /// Encodes the operator as Komga's `is` equality condition.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("is", forKey: .operator)
        try container.encode(value, forKey: .value)
    }
}

/// Restricts a series search to one library.
struct SeriesSearchConditionDto: Encodable {
    let libraryId: SearchEqualityDto
}

/// Restricts a book search to one series.
struct BookSearchConditionDto: Encodable {
    let seriesId: SearchEqualityDto
}

/// Request body for the Komga series list endpoint.
struct SeriesSearchRequestDto: Encodable {
    let condition: SeriesSearchConditionDto?
    let fullTextSearch: String
}

/// Request body for the Komga books list endpoint.
struct BookSearchRequestDto: Encodable {
    let condition: BookSearchConditionDto
    let fullTextSearch: String
}

/// Stable `sort` query tokens sent to Komga list endpoints.
///
/// Values are `field,direction` strings accepted by Komga's `sort` parameter.
enum KomgaSort {
    /// Series list default, matching Komga Web UI title order.
    static let seriesTitleAsc = "metadata.titleSort,asc"
    /// Books in a series, matching Komga Web UI number order.
    static let bookNumberAsc = "metadata.numberSort,asc"
    /// Keep Reading: most recently read first.
    static let readProgressDateDesc = "readProgress.readDate,desc"
}
