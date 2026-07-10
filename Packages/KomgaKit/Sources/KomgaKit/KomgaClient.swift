import Foundation
import os

/// A typed, stateless client for the Komga v1 API.
///
/// All requests carry the `X-API-Key` header. Data-returning methods are
/// `async` and decode JSON into `KomgaKit` DTOs; image and file endpoints
/// return a pre-authenticated `URLRequest` for the caller to execute (so that
/// downloading and caching strategy stays outside this type).
public struct KomgaClient: Sendable {
    private static let logger = Logger(subsystem: "jp.moongift.dokusho", category: "KomgaKit")

    private let builder: RequestBuilder
    private let session: URLSession

    /// Creates a client for the given server configuration.
    ///
    /// - Parameters:
    ///   - config: The validated server configuration.
    ///   - session: The `URLSession` used for data tasks. Defaults to `.shared`.
    public init(config: KomgaServerConfig, session: URLSession = .shared) {
        builder = RequestBuilder(config: config)
        self.session = session
    }

    // MARK: - Connection / auth

    /// Fetches the authenticated user. Doubles as a connection/auth check.
    public func currentUser() async throws -> KomgaUser {
        try await get(path: "/api/v2/users/me")
    }

    // MARK: - Lists

    /// Fetches all libraries visible to the user.
    public func libraries() async throws -> [KomgaLibrary] {
        try await get(path: "/api/v1/libraries")
    }

    /// Fetches a page of series, optionally filtered by library and search text.
    public func series(
        libraryID: String?,
        search: String?,
        page: Int,
        size: Int
    ) async throws -> Page<KomgaSeries> {
        var query = paginationQuery(page: page, size: size)
        if let libraryID, !libraryID.isEmpty {
            query.append(URLQueryItem(name: "library_id", value: libraryID))
        }
        if let search, !search.isEmpty {
            query.append(URLQueryItem(name: "search", value: search))
        }
        return try await get(path: "/api/v1/series", queryItems: query)
    }

    /// Fetches a page of books in a series.
    public func books(
        seriesID: String,
        page: Int,
        size: Int
    ) async throws -> Page<KomgaBook> {
        try await get(
            path: "/api/v1/series/\(seriesID)/books",
            queryItems: paginationQuery(page: page, size: size)
        )
    }

    /// Fetches a single series by id.
    public func series(id: String) async throws -> KomgaSeries {
        try await get(path: "/api/v1/series/\(id)")
    }

    /// Fetches a single book by id.
    public func book(id: String) async throws -> KomgaBook {
        try await get(path: "/api/v1/books/\(id)")
    }

    // MARK: - Home

    /// Fetches in-progress books ("Keep Reading"), most recently read first.
    public func keepReading(page: Int, size: Int) async throws -> Page<KomgaBook> {
        var query = paginationQuery(page: page, size: size)
        query.append(URLQueryItem(name: "read_status", value: "IN_PROGRESS"))
        query.append(URLQueryItem(name: "sort", value: "readProgress.readDate,desc"))
        return try await get(path: "/api/v1/books", queryItems: query)
    }

    /// Fetches "On Deck" books (next to read).
    public func onDeck(page: Int, size: Int) async throws -> Page<KomgaBook> {
        try await get(
            path: "/api/v1/books/ondeck",
            queryItems: paginationQuery(page: page, size: size)
        )
    }

    // MARK: - Collections / read lists

    /// Fetches a page of collections.
    public func collections(page: Int, size: Int) async throws -> Page<KomgaCollection> {
        try await get(
            path: "/api/v1/collections",
            queryItems: paginationQuery(page: page, size: size)
        )
    }

    /// Fetches a page of series within a collection.
    public func collectionSeries(
        id: String,
        page: Int,
        size: Int
    ) async throws -> Page<KomgaSeries> {
        try await get(
            path: "/api/v1/collections/\(id)/series",
            queryItems: paginationQuery(page: page, size: size)
        )
    }

    /// Fetches a page of read lists.
    public func readLists(page: Int, size: Int) async throws -> Page<KomgaReadList> {
        try await get(
            path: "/api/v1/readlists",
            queryItems: paginationQuery(page: page, size: size)
        )
    }

    /// Fetches a page of books within a read list.
    public func readListBooks(
        id: String,
        page: Int,
        size: Int
    ) async throws -> Page<KomgaBook> {
        try await get(
            path: "/api/v1/readlists/\(id)/books",
            queryItems: paginationQuery(page: page, size: size)
        )
    }

    // MARK: - Pages / streaming

    /// Fetches the page list (page count, dimensions, media types) for a book.
    public func pages(bookID: String) async throws -> [KomgaPage] {
        try await get(path: "/api/v1/books/\(bookID)/pages")
    }

    /// Builds a request for a single page image.
    ///
    /// - Parameters:
    ///   - bookID: The book id.
    ///   - page: The page number (1-based).
    ///   - convert: An optional server-side format conversion.
    /// - Returns: An authenticated `URLRequest` for the page image.
    /// - Throws: ``KomgaError/insecureURL`` if the URL cannot be built.
    public func pageImageRequest(
        bookID: String,
        page: Int,
        convert: ImageConversion?
    ) throws -> URLRequest {
        var query: [URLQueryItem] = []
        if let convert {
            query.append(URLQueryItem(name: "convert", value: convert.rawValue))
        }
        return try builder.makeRequest(
            path: "/api/v1/books/\(bookID)/pages/\(page)",
            queryItems: query,
            accept: "image/*"
        )
    }

    // MARK: - Download

    /// Builds a request to download a book's original file (ePub/PDF).
    public func fileDownloadRequest(bookID: String) throws -> URLRequest {
        try builder.makeRequest(path: "/api/v1/books/\(bookID)/file", accept: "*/*")
    }

    // MARK: - Thumbnail

    /// Builds a request for a resource's thumbnail image.
    public func thumbnailRequest(for target: ThumbnailTarget) throws -> URLRequest {
        try builder.makeRequest(path: target.path, accept: "image/*")
    }

    // MARK: - Progress

    /// Updates the current user's read progress for a book.
    ///
    /// - Parameters:
    ///   - bookID: The book id.
    ///   - page: The last page read (1-based). Omit when marking complete.
    ///   - completed: Whether the book is complete. When `nil`, Komga derives
    ///     it from `page` and the book's page count.
    public func updateReadProgress(
        bookID: String,
        page: Int?,
        completed: Bool?
    ) async throws {
        let body = try JSONEncoder().encode(
            ReadProgressUpdateDto(page: page, completed: completed)
        )
        let request = try builder.makeRequest(
            method: "PATCH",
            path: "/api/v1/books/\(bookID)/read-progress",
            body: body
        )
        _ = try await performExpectingNoContent(request)
    }

    // MARK: - Private helpers

    private func paginationQuery(page: Int, size: Int) -> [URLQueryItem] {
        [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "size", value: String(size)),
        ]
    }

    private func get<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> T {
        let request = try builder.makeRequest(path: path, queryItems: queryItems)
        let data = try await perform(request)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            Self.logger.error(
                "Decoding failed for \(path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            throw KomgaError.decoding(error)
        }
    }

    /// Executes a request, validating the status code, returning the body data.
    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw KomgaError.network(urlError)
        } catch {
            throw KomgaError.network(URLError(.unknown))
        }
        try Self.validate(response)
        return data
    }

    /// Executes a request expecting an empty/ignored body, validating status.
    private func performExpectingNoContent(_ request: URLRequest) async throws -> Data {
        try await perform(request)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw KomgaError.network(URLError(.badServerResponse))
        }
        if let error = KomgaError.fromStatus(http.statusCode) {
            throw error
        }
    }

    /// A shared decoder for Komga's date-time formats. Komga serializes
    /// `LocalDateTime` **without** a timezone designator (e.g.
    /// `2024-05-31T09:00:00` or with a variable-length fraction); such values
    /// are interpreted as UTC. Zone-suffixed ISO-8601 values are also accepted.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = KomgaDateParser.parse(string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized Komga date: \(string)"
            )
        }
        return decoder
    }()
}
