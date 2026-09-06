import Foundation
import KomgaKit

/// Value-based navigation destinations for the browse hierarchy.
///
/// Pushed onto a `NavigationStack` via `navigationDestination(for:)`. Keeping
/// them in one enum lets any screen navigate to any other without threading
/// closures through the view tree.
enum BrowseRoute: Hashable {
    /// The series grid for a specific library (or all libraries when `nil`).
    case library(id: String?, title: String)
    /// The book list for a series.
    case series(KomgaSeries)
    /// A book's detail screen.
    case book(KomgaBook)
    /// The series grid within a collection.
    case collection(KomgaCollection)
    /// The book list within a read list.
    case readList(KomgaReadList)

    // KomgaKit DTOs are `Equatable` but not `Hashable`; identity is fully
    // captured by each resource's stable id, so hashing/equality use those.
    static func == (lhs: BrowseRoute, rhs: BrowseRoute) -> Bool {
        lhs.identity == rhs.identity
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(identity)
    }

    private var identity: String {
        switch self {
        case let .library(id, title): return "library:\(id ?? "all"):\(title)"
        case let .series(series): return "series:\(series.id)"
        case let .book(book): return "book:\(book.id)"
        case let .collection(collection): return "collection:\(collection.id)"
        case let .readList(readList): return "readList:\(readList.id)"
        }
    }
}
