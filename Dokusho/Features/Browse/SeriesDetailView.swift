import SwiftUI
import KomgaKit

/// The book list for a series, with a `.searchable` filter over its books.
///
/// Books are paginated via ``PaginatedList``. Search filters fetched pages
/// client-side by title, matching the app's "search within" affordance.
struct SeriesDetailView: View {
    let series: KomgaSeries

    @Environment(AppServices.self) private var services
    @State private var searchText = ""
    @State private var list: PaginatedList<KomgaBook>?

    var body: some View {
        Group {
            if let list {
                BookList(list: list)
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .navigationTitle(series.metadata.title.isEmpty ? series.name : series.metadata.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "このシリーズ内を検索")
        .task(id: searchKey) { await rebuildList() }
    }

    private var searchKey: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rebuildList() async {
        // Debounce only real queries; an empty search key (first render, or the
        // user clearing the field) should rebuild immediately.
        if !searchKey.isEmpty {
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard !Task.isCancelled, let client = services.client else { return }
        let seriesID = series.id
        let query = searchKey.lowercased()
        var filter: (@Sendable (KomgaBook) -> Bool)?
        if !query.isEmpty {
            filter = { book in
                book.metadata.title.lowercased().contains(query)
                    || book.name.lowercased().contains(query)
            }
        }
        list = PaginatedList<KomgaBook>(filter: filter) { page, size in
            try await client.books(seriesID: seriesID, page: page, size: size)
        }
    }
}
