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
