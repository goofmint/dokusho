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
    @State private var listSearchKey: String?

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
        let key = searchKey
        guard list == nil || listSearchKey != key else { return }

        // Debounce only real queries; an empty search key (first render, or the
        // user clearing the field) should rebuild immediately.
        if !key.isEmpty {
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard !Task.isCancelled, searchKey == key, let client = services.client else { return }
        let seriesID = series.id
        let query = key.lowercased()
        var filter: (@Sendable (KomgaBook) -> Bool)?
        if !query.isEmpty {
            filter = { book in
                book.metadata.title.lowercased().contains(query)
                    || book.name.lowercased().contains(query)
            }
        }
        let cache: BrowseCache? = query.isEmpty ? .shared : nil
        let cacheKey = query.isEmpty ? "series-books-\(seriesID)" : nil
        list = PaginatedList<KomgaBook>(filter: filter, cache: cache, cacheKey: cacheKey) { page, size in
            try await client.books(seriesID: seriesID, page: page, size: size)
        }
        listSearchKey = key
    }
}
