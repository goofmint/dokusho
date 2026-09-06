import SwiftUI
import KomgaKit

/// The book list for a series, with a `.searchable` filter over its books.
///
/// Books are paginated via ``PaginatedList`` and searched on the server.
struct SeriesDetailView: View {
    let series: KomgaSeries

    @Environment(AppServices.self) private var services
    @Environment(DownloadManager.self) private var downloadManager
    @State private var searchText = ""
    @State private var list: PaginatedList<KomgaBook>?
    @State private var listSearchKey: String?
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var confirmsDownload = false
    @State private var downloadError: String?

    var body: some View {
        Group {
            if let list {
                BookList(list: list, selectedIDs: isSelecting ? $selectedIDs : nil)
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .navigationTitle(series.metadata.title.isEmpty ? series.name : series.metadata.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "このシリーズ内を検索")
        .task(id: searchKey) { await rebuildList() }
        .onChange(of: searchKey) { selectedIDs.removeAll() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSelecting ? "完了" : "選択") {
                    isSelecting.toggle()
                    selectedIDs.removeAll()
                    downloadError = nil
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                HStack {
                    Button("表示中を選択") {
                        selectedIDs = Set((list?.items ?? []).filter(downloadManager.canDownload).map(\.id))
                    }
                    Button("選択解除") { selectedIDs.removeAll() }
                    Spacer()
                    Button("ダウンロード（\(selectedBooks.count)冊）") {
                        confirmsDownload = true
                    }
                    .disabled(selectedBooks.isEmpty)
                }
                .font(.footnote)
                .padding()
                .background(.bar)
            }
        }
        .safeAreaInset(edge: .top) {
            if let downloadError {
                Label(downloadError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red).padding()
            }
        }
        .confirmationDialog("\(selectedBooks.count)冊をダウンロードしますか？", isPresented: $confirmsDownload, titleVisibility: .visible) {
            Button("ダウンロード", action: downloadSelectedBooks)
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("選択した書籍を端末に保存します。")
        }
    }

    /// Currently selected books that can start a download.
    private var selectedBooks: [KomgaBook] {
        (list?.items ?? []).filter { selectedIDs.contains($0.id) && downloadManager.canDownload($0) }
    }

    /// Starts eligible selections and reports startup errors without stopping the batch.
    private func downloadSelectedBooks() {
        let failures = downloadManager.download(books: selectedBooks)
        downloadError = failures.isEmpty ? nil : "\(failures.count)冊のダウンロードを開始できませんでした。再度選択してお試しください。"
        selectedIDs.removeAll()
        isSelecting = false
    }

    /// Trimmed series search query used as the list identity.
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
