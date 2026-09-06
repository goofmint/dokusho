import SwiftUI
import KomgaKit

/// The book list for a series, with a `.searchable` filter over its books.
///
/// Books are paginated via ``PaginatedList`` and searched on the server.
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

    /// Rebuilds only for a changed query, caching unfiltered first-page results.
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
        let cache: BrowseCache? = key.isEmpty ? .shared : nil
        let cacheKey = key.isEmpty ? "series-books-\(seriesID)" : nil
        list = PaginatedList<KomgaBook>(cache: cache, cacheKey: cacheKey) { page, size in
            if key.isEmpty {
                return try await client.books(seriesID: seriesID, page: page, size: size)
            }
            return try await client.booksSearch(
                seriesID: seriesID, fullTextSearch: key, page: page, size: size
            )
        }
        listSearchKey = key
    }
}
