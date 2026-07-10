import Foundation

/// One unit shown by the pager: either a single page or a two-page spread.
///
/// Page numbers are **1-based** (Komga convention). In a ``spread`` the two
/// numbers are stored in *reading order* — `leading` is read first. The view is
/// responsible for placing them on the correct side of the screen given the
/// reading progression (see ``ReaderLayout``).
enum ReaderSpread: Equatable {
    /// A single page (cover, a trailing odd page, or single-page mode).
    case single(page: Int)
    /// A two-page spread, `first` read before `second` (reading order).
    case spread(first: Int, second: Int)

    /// The first page in reading order — used to record progress for the unit.
    var readingOrderFirstPage: Int {
        switch self {
        case let .single(page): return page
        case let .spread(first, _): return first
        }
    }

    /// The highest page number this unit covers (for "last page reached").
    var maxPage: Int {
        switch self {
        case let .single(page): return page
        case let .spread(first, second): return max(first, second)
        }
    }

    /// All pages this unit covers, for prefetch accounting.
    var pages: [Int] {
        switch self {
        case let .single(page): return [page]
        case let .spread(first, second): return [first, second]
        }
    }
}

/// Computes the ordered list of ``ReaderSpread`` units for a book.
///
/// The array is always in **reading order**: index 0 is the first unit the user
/// sees, regardless of LTR/RTL. Gesture/side placement is derived from
/// ``progression`` by the view layer, not by reordering this array.
///
/// Spread rules (design.md §2.3, §10):
/// - Single-page mode → every page is its own ``ReaderSpread/single``.
/// - Spread mode → the cover (page 1) is always ``single``; pages 2.. are paired
///   `(2,3),(4,5),…`; if a trailing page has no partner it is ``single``.
struct ReaderLayout: Equatable {
    /// Total pages in the book (1-based, so pages are `1...pageCount`).
    let pageCount: Int
    /// Whether two-page spreads are used (landscape / regular width).
    let usesSpread: Bool
    /// The reading progression (affects side placement, not this array's order).
    let progression: ReadingProgression

    /// The ordered spreads, in reading order.
    let spreads: [ReaderSpread]

    init(pageCount: Int, usesSpread: Bool, progression: ReadingProgression) {
        self.pageCount = pageCount
        self.usesSpread = usesSpread
        self.progression = progression
        self.spreads = Self.buildSpreads(pageCount: pageCount, usesSpread: usesSpread)
    }

    private static func buildSpreads(pageCount: Int, usesSpread: Bool) -> [ReaderSpread] {
        guard pageCount > 0 else { return [] }
        guard usesSpread else {
            return (1...pageCount).map { .single(page: $0) }
        }
        var result: [ReaderSpread] = [.single(page: 1)]
        var page = 2
        while page <= pageCount {
            if page + 1 <= pageCount {
                result.append(.spread(first: page, second: page + 1))
                page += 2
            } else {
                result.append(.single(page: page))
                page += 1
            }
        }
        return result
    }

    /// The spread index that contains the given 1-based page, or 0 if not found.
    func spreadIndex(containing page: Int) -> Int {
        for (index, spread) in spreads.enumerated() where spread.pages.contains(page) {
            return index
        }
        return 0
    }

    /// Whether the given spread index is the last unit (book end).
    func isLastSpread(_ index: Int) -> Bool {
        index == spreads.count - 1
    }
}
