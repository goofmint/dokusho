import SwiftUI
import KomgaKit

/// Registers `navigationDestination` handlers for every ``BrowseRoute`` and
/// ``ReaderDestination`` value.
///
/// Applied once per `NavigationStack` (library, collections, read lists, home)
/// so any pushed route resolves consistently.
struct BrowseDestinationsModifier: ViewModifier {
    @Environment(AppServices.self) private var services

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: BrowseRoute.self) { route in
                destination(for: route)
            }
            .navigationDestination(for: ReaderDestination.self) { destination in
                switch destination {
                case let .book(book):
                    ReaderRootView(book: book)
                }
            }
    }

    @ViewBuilder
    private func destination(for route: BrowseRoute) -> some View {
        switch route {
        case let .library(id, title):
            LibrarySeriesView(libraryID: id, title: title)
        case let .series(series):
            SeriesDetailView(series: series)
        case let .book(book):
            BookDetailView(book: book)
        case let .collection(collection):
            CollectionDetailView(collection: collection)
        case let .readList(readList):
            ReadListDetailView(readList: readList)
        }
    }
}

extension View {
    /// Registers all browse and reader navigation destinations on this stack.
    func browseDestinations() -> some View {
        modifier(BrowseDestinationsModifier())
    }
}
