import Foundation
import KomgaKit

/// Resolves the next book in the same series, using Komga's `numberSort`
/// order (the same order as ``KomgaClient/books(seriesID:page:size:)``).
///
/// ``KomgaBook/number`` is not used: it is a display / file order and may
/// disagree with `numberSort`. Offline callers (`client == nil`) and any
/// fetch failure return `nil`.
enum NextVolumeResolver {
    /// Returns the book after `current` in the series, or `nil` when there is
    /// no successor, the client is unavailable, or the series cannot be listed.
    static func resolve(current: KomgaBook, client: KomgaClient?) async -> KomgaBook? {
        guard let client else { return nil }
        do {
            let series = try await client.series(id: current.seriesId)
            let books = try await fetchAllBooks(
                seriesID: current.seriesId,
                booksCount: series.booksCount,
                client: client
            )
            guard let index = books.firstIndex(where: { $0.id == current.id }) else {
                return nil
            }
            let nextIndex = books.index(after: index)
            guard nextIndex < books.endIndex else { return nil }
            return books[nextIndex]
        } catch {
            return nil
        }
    }

    /// Pages through `books(seriesID:)` until `Page.last` (or an empty page).
    private static func fetchAllBooks(
        seriesID: String,
        booksCount: Int,
        client: KomgaClient
    ) async throws -> [KomgaBook] {
        let pageSize = max(booksCount, 1)
        var books: [KomgaBook] = []
        var pageIndex = 0
        while true {
            let page = try await client.books(seriesID: seriesID, page: pageIndex, size: pageSize)
            books.append(contentsOf: page.content)
            if page.last || page.content.isEmpty {
                break
            }
            pageIndex += 1
        }
        return books
    }
}
