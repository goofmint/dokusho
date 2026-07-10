import Foundation
import Observation
import KomgaKit

/// The default page size for all list/grid pagination (design §8.2).
let browsePageSize = 50

/// A generic, `@Observable` pagination controller for a Komga `Page<Element>`
/// endpoint, driving infinite scroll for both series grids and book lists.
///
/// It owns the accumulated items, the loading/error state, and whether more
/// pages remain. The concrete endpoint is supplied as a closure so one type
/// serves series, books, collections, and read lists.
@MainActor
@Observable
final class PaginatedList<Element: Sendable & Decodable & Identifiable & Equatable> {
    /// The distinct phases a paginated screen can be in.
    enum Phase: Equatable {
        /// No load has started yet.
        case idle
        /// The first page is loading (full-screen spinner).
        case loadingFirst
        /// At least one page has loaded successfully.
        case loaded
        /// The first-page load failed (full-screen error with retry).
        case failed(String)
    }

    private(set) var items: [Element] = []
    private(set) var phase: Phase = .idle
    private(set) var isLoadingMore = false

    /// Whether more pages remain on the server.
    private var hasMore = true
    /// The next zero-based page index to request.
    private var nextPage = 0
    /// Guards against overlapping loads.
    private var isLoading = false

    /// Fetches a page for the given zero-based index and size.
    private let fetch: @Sendable (_ page: Int, _ size: Int) async throws -> Page<Element>
    /// Optional client-side filter applied to each fetched page's items.
    private let filter: (@Sendable (Element) -> Bool)?

    init(
        filter: (@Sendable (Element) -> Bool)? = nil,
        fetch: @escaping @Sendable (_ page: Int, _ size: Int) async throws -> Page<Element>
    ) {
        self.filter = filter
        self.fetch = fetch
    }

    /// Loads the first page if nothing has loaded yet. Idempotent across
    /// `onAppear` re-entry.
    func loadInitialIfNeeded() async {
        guard case .idle = phase else { return }
        await reload()
    }

    /// Discards accumulated state and reloads from the first page.
    func reload() async {
        items = []
        nextPage = 0
        hasMore = true
        phase = .loadingFirst
        await loadNextPage(isInitial: true)
    }

    /// Loads the next page when the user scrolls near the given item.
    func loadMoreIfNeeded(currentItem: Element) async {
        guard hasMore, !isLoading else { return }
        // Trigger when the last few items become visible.
        let thresholdIndex = items.index(items.endIndex, offsetBy: -5, limitedBy: items.startIndex) ?? items.startIndex
        if let currentIndex = items.firstIndex(of: currentItem), currentIndex >= thresholdIndex {
            await loadNextPage(isInitial: false)
        }
    }

    private func loadNextPage(isInitial: Bool) async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        if !isInitial { isLoadingMore = true }
        defer {
            isLoading = false
            isLoadingMore = false
        }

        do {
            let page = try await fetch(nextPage, browsePageSize)
            let newItems = filter.map { page.content.filter($0) } ?? page.content
            items.append(contentsOf: newItems)
            hasMore = !page.last
            nextPage += 1
            phase = .loaded
        } catch is CancellationError {
            // Screen dismissed; leave state as-is.
        } catch {
            if isInitial {
                phase = .failed(ErrorMessage.text(for: error))
            }
            // For subsequent pages, keep showing what we have; the row spinner
            // simply stops. A later scroll retries.
        }
    }
}
