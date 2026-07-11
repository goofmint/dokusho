import Foundation
import Observation
import os
import KomgaKit

/// The default page size for all list/grid pagination (design §8.2).
let browsePageSize = 50

/// Logs first-page revalidation failures (cached data is kept, no error shown).
private let revalidationLogger = Logger(subsystem: "jp.moongift.dokusho", category: "BrowseRevalidate")

/// A generic, `@Observable` pagination controller for a Komga `Page<Element>`
/// endpoint, driving infinite scroll for both series grids and book lists.
///
/// It owns the accumulated items, the loading/error state, and whether more
/// pages remain. The concrete endpoint is supplied as a closure so one type
/// serves series, books, collections, and read lists.
@MainActor
@Observable
final class PaginatedList<Element: Sendable & Codable & Identifiable & Equatable> {
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

    /// Optional first-page cache for stale-while-revalidate. When present, the
    /// first page is served from disk immediately and refreshed in the
    /// background; page 0 is written back on every successful network load.
    /// Absent for search results, which are never cached.
    private let cache: BrowseCache?
    /// The cache key identifying this query (e.g. "libraries", "series-{id}").
    private let cacheKey: String?

    init(
        filter: (@Sendable (Element) -> Bool)? = nil,
        cache: BrowseCache? = nil,
        cacheKey: String? = nil,
        fetch: @escaping @Sendable (_ page: Int, _ size: Int) async throws -> Page<Element>
    ) {
        self.filter = filter
        self.cache = cache
        self.cacheKey = cacheKey
        self.fetch = fetch
    }

    /// Loads the first page if nothing has loaded yet. Idempotent across
    /// `onAppear` re-entry.
    ///
    /// When a first-page cache is configured, this shows any cached page
    /// immediately (no spinner) and then revalidates against the network,
    /// replacing the displayed data and refreshing the cache on success and
    /// keeping the cached data on failure. Without a cache it behaves as a plain
    /// first-page load.
    func loadInitialIfNeeded() async {
        guard case .idle = phase else { return }

        if let cache, let cacheKey,
           let cached = await cache.load(Page<Element>.self, key: cacheKey) {
            // Show cached results immediately, then revalidate in the background.
            applyFirstPage(cached)
            await revalidateFirstPage()
        } else {
            await reload()
        }
    }

    /// Discards accumulated state and reloads from the first page over the
    /// network. Drives pull-to-refresh and retry; refreshes the cache on success.
    func reload() async {
        items = []
        nextPage = 0
        hasMore = true
        phase = .loadingFirst
        await loadNextPage(isInitial: true)
    }

    /// Fetches page 0 without showing a spinner, keeping the already-displayed
    /// (cached) data if the network fails. Used only after a cache hit.
    private func revalidateFirstPage() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await fetch(0, browsePageSize)
            applyFirstPage(page)
            if let cache, let cacheKey {
                await cache.save(page, key: cacheKey)
            }
        } catch is CancellationError {
            // Screen dismissed; keep cached data.
        } catch {
            // Revalidation failed: keep showing the cached page. There is cached
            // data on screen, so no error view — only log.
            revalidationLogger.error("Browse revalidation failed for \(self.cacheKey ?? "?", privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Replaces the accumulated items with a fresh first page and resets
    /// pagination cursors so subsequent scrolls continue from page 1.
    private func applyFirstPage(_ page: Page<Element>) {
        let newItems = filter.map { page.content.filter($0) } ?? page.content
        items = newItems
        hasMore = !page.last
        nextPage = 1
        phase = .loaded
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
            let requestedPage = nextPage
            let page = try await fetch(requestedPage, browsePageSize)
            let newItems = filter.map { page.content.filter($0) } ?? page.content
            items.append(contentsOf: newItems)
            hasMore = !page.last
            nextPage += 1
            phase = .loaded
            // Cache the first page only; later pages stay network-only.
            if requestedPage == 0, let cache, let cacheKey {
                await cache.save(page, key: cacheKey)
            }
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
