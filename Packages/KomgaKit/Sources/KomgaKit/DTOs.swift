import Foundation

// MARK: - Pagination

/// A page of results from a Komga paginated endpoint.
///
/// Mirrors the Spring Data `Page` JSON shape used across the Komga v1 API.
/// Only the fields the app consumes are decoded; unrelated fields such as
/// `pageable` and `sort` are ignored.
public struct Page<Element: Sendable & Decodable>: Sendable, Decodable {
    /// The elements on this page.
    public let content: [Element]
    /// Zero-based index of this page.
    public let number: Int
    /// The requested page size.
    public let size: Int
    /// Total number of elements across all pages.
    public let totalElements: Int
    /// Total number of pages.
    public let totalPages: Int
    /// Number of elements actually present on this page.
    public let numberOfElements: Int
    /// Whether this is the first page.
    public let first: Bool
    /// Whether this is the last page.
    public let last: Bool
    /// Whether this page has no elements.
    public let empty: Bool

    private enum CodingKeys: String, CodingKey {
        case content, number, size, totalElements, totalPages
        case numberOfElements, first, last, empty
    }
}

// MARK: - Library

/// A Komga library.
public struct KomgaLibrary: Sendable, Decodable, Identifiable, Equatable {
    public let id: String
    public let name: String
    /// Whether the library is currently unavailable (e.g. offline storage).
    public let unavailable: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, unavailable
    }
}

// MARK: - Reading direction

/// The reading progression of a series, from ``KomgaSeriesMetadata``.
///
/// The raw string is preserved so unknown future values do not cause a decode
/// failure; ``unknown`` carries the original value for diagnostics.
public enum KomgaReadingDirection: Sendable, Equatable {
    case leftToRight
    case rightToLeft
    case vertical
    case webtoon
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "LEFT_TO_RIGHT": self = .leftToRight
        case "RIGHT_TO_LEFT": self = .rightToLeft
        case "VERTICAL": self = .vertical
        case "WEBTOON": self = .webtoon
        default: self = .unknown(rawValue)
        }
    }
}

// MARK: - Series

/// A Komga series.
public struct KomgaSeries: Sendable, Decodable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let libraryId: String
    public let metadata: KomgaSeriesMetadata
    public let booksCount: Int
    public let booksReadCount: Int
    public let booksUnreadCount: Int
    public let booksInProgressCount: Int

    private enum CodingKeys: String, CodingKey {
        case id, name, libraryId, metadata
        case booksCount, booksReadCount, booksUnreadCount, booksInProgressCount
    }
}

/// Metadata for a ``KomgaSeries``.
public struct KomgaSeriesMetadata: Sendable, Decodable, Equatable {
    public let title: String
    public let status: String
    public let summary: String
    public let publisher: String
    public let language: String
    /// The typed reading direction.
    public let readingDirection: KomgaReadingDirection
    /// The raw reading-direction string as returned by the server.
    public let readingDirectionRaw: String

    private enum CodingKeys: String, CodingKey {
        case title, status, summary, publisher, language, readingDirection
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        status = try container.decode(String.self, forKey: .status)
        summary = try container.decode(String.self, forKey: .summary)
        publisher = try container.decode(String.self, forKey: .publisher)
        language = try container.decode(String.self, forKey: .language)
        let raw = try container.decode(String.self, forKey: .readingDirection)
        readingDirectionRaw = raw
        readingDirection = KomgaReadingDirection(rawValue: raw)
    }
}

// MARK: - Book

/// A Komga book.
public struct KomgaBook: Sendable, Decodable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let seriesId: String
    public let seriesTitle: String
    public let libraryId: String
    public let number: Int
    public let media: KomgaMedia
    public let metadata: KomgaBookMetadata
    /// The reading progress for the current user, or `nil` if unread.
    public let readProgress: KomgaReadProgress?
    /// File size in bytes.
    public let sizeBytes: Int

    private enum CodingKeys: String, CodingKey {
        case id, name, seriesId, seriesTitle, libraryId, number
        case media, metadata, readProgress, sizeBytes
    }
}

/// Media details for a ``KomgaBook``.
public struct KomgaMedia: Sendable, Decodable, Equatable {
    /// The media profile, e.g. `EPUB`, `PDF`, `DIVINA`.
    public let mediaProfile: String
    /// The container media type, e.g. `application/epub+zip`.
    public let mediaType: String
    /// The number of pages Komga has analyzed for this book.
    public let pagesCount: Int
    /// The analysis status, e.g. `READY`.
    public let status: String

    private enum CodingKeys: String, CodingKey {
        case mediaProfile, mediaType, pagesCount, status
    }
}

/// Metadata for a ``KomgaBook``.
public struct KomgaBookMetadata: Sendable, Decodable, Equatable {
    public let title: String
    public let number: String
    public let summary: String
    public let authors: [KomgaAuthor]

    private enum CodingKeys: String, CodingKey {
        case title, number, summary, authors
    }
}

/// An author credit within ``KomgaBookMetadata``.
public struct KomgaAuthor: Sendable, Decodable, Equatable {
    public let name: String
    public let role: String
}

/// The current user's read progress for a ``KomgaBook``.
public struct KomgaReadProgress: Sendable, Decodable, Equatable {
    /// The last page read (1-based).
    public let page: Int
    /// Whether the book has been completed.
    public let completed: Bool
    /// When the book was last read.
    public let readDate: Date

    private enum CodingKeys: String, CodingKey {
        case page, completed, readDate
    }
}

// MARK: - Page

/// A single page within a book, from `GET /books/{id}/pages`.
public struct KomgaPage: Sendable, Decodable, Equatable {
    /// The page number (1-based).
    public let number: Int
    public let fileName: String
    public let mediaType: String
    /// Pixel width, when analyzed.
    public let width: Int?
    /// Pixel height, when analyzed.
    public let height: Int?

    private enum CodingKeys: String, CodingKey {
        case number, fileName, mediaType, width, height
    }
}

// MARK: - Collection

/// A Komga collection (an ordered/unordered group of series).
public struct KomgaCollection: Sendable, Decodable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let ordered: Bool
    public let seriesIds: [String]

    private enum CodingKeys: String, CodingKey {
        case id, name, ordered, seriesIds
    }
}

// MARK: - ReadList

/// A Komga read list (an ordered/unordered group of books).
public struct KomgaReadList: Sendable, Decodable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let summary: String
    public let ordered: Bool
    public let bookIds: [String]

    private enum CodingKeys: String, CodingKey {
        case id, name, summary, ordered, bookIds
    }
}

// MARK: - User

/// The authenticated Komga user, from `GET /api/v2/users/me`.
public struct KomgaUser: Sendable, Decodable, Identifiable, Equatable {
    public let id: String
    public let email: String
    public let roles: [String]

    private enum CodingKeys: String, CodingKey {
        case id, email, roles
    }
}

// MARK: - Request bodies

/// Body for `PATCH /books/{id}/read-progress`.
///
/// `page` may be omitted when `completed` is `true`; `completed` may be omitted
/// and Komga derives it from the page and the book's total page count.
struct ReadProgressUpdateDto: Encodable {
    let page: Int?
    let completed: Bool?
}
