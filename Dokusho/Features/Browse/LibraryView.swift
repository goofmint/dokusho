import SwiftUI
import Observation
import os
import KomgaKit

/// Logs library revalidation failures (cached data is kept, no error shown).
private let libraryLogger = Logger(subsystem: "jp.moongift.dokusho", category: "BrowseLibraries")

/// Root browse screen: the list of libraries plus an "all series" entry.
///
/// Each row pushes ``BrowseRoute/library(id:title:)`` which renders the
/// paginated series grid. This view owns the browse `NavigationStack`.
struct LibraryView: View {
    @Environment(AppServices.self) private var services
    @State private var viewModel = LibraryListViewModel()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("ライブラリ")
                .browseDestinations()
                .task { await viewModel.loadIfNeeded(client: services.client) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle, .loading:
            ProgressView().controlSize(.large)
        case let .failed(message):
            ErrorStateView(message: message) {
                Task { await viewModel.reload(client: services.client) }
            }
        case .loaded:
            List {
                NavigationLink(value: BrowseRoute.library(id: nil, title: "すべてのシリーズ")) {
                    Label("すべてのシリーズ", systemImage: "square.grid.2x2")
                }
                Section("ライブラリ") {
                    ForEach(viewModel.libraries) { library in
                        NavigationLink(value: BrowseRoute.library(id: library.id, title: library.name)) {
                            Label(library.name, systemImage: "books.vertical")
                                .foregroundStyle(library.unavailable ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        }
                        .disabled(library.unavailable)
                    }
                }
            }
            .refreshable { await viewModel.reload(client: services.client) }
        }
    }
}

/// Loads the library list for the root browse screen.
@MainActor
@Observable
final class LibraryListViewModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var libraries: [KomgaLibrary] = []
    private(set) var phase: Phase = .idle

    private let cache = BrowseCache.shared
    private let cacheKey = "libraries"

    /// On first appear, show any cached libraries immediately, then revalidate
    /// against the network (replacing the list and refreshing the cache on
    /// success; keeping cached data on failure).
    func loadIfNeeded(client: KomgaClient?) async {
        guard case .idle = phase else { return }

        if let cached = await cache.load([KomgaLibrary].self, key: cacheKey) {
            libraries = cached
            phase = .loaded
            await revalidate(client: client)
        } else {
            await reload(client: client)
        }
    }

    /// Forces a fresh fetch (pull-to-refresh / retry) and refreshes the cache.
    func reload(client: KomgaClient?) async {
        guard let client else {
            phase = .failed("サーバーに接続していません。")
            return
        }
        phase = .loading
        do {
            let fresh = try await client.libraries()
            libraries = fresh
            phase = .loaded
            await cache.save(fresh, key: cacheKey)
        } catch is CancellationError {
        } catch {
            phase = .failed(ErrorMessage.text(for: error))
        }
    }

    /// Fetches without a spinner, keeping cached data if the network fails.
    private func revalidate(client: KomgaClient?) async {
        guard let client else { return }
        do {
            let fresh = try await client.libraries()
            libraries = fresh
            phase = .loaded
            await cache.save(fresh, key: cacheKey)
        } catch is CancellationError {
        } catch {
            // Keep showing cached libraries; no error view when cache is present.
            libraryLogger.error("Libraries revalidation failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// The paginated series grid for a library (or all libraries when `libraryID`
/// is `nil`), with a `.searchable` filter.
struct LibrarySeriesView: View {
    let libraryID: String?
    let title: String

    @Environment(AppServices.self) private var services
    @State private var searchText = ""
    @State private var list: PaginatedList<KomgaSeries>?

    var body: some View {
        Group {
            if let list {
                SeriesGrid(list: list)
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .navigationTitle(title)
        .searchable(text: $searchText, prompt: "シリーズを検索")
        .task(id: searchQueryKey) { await rebuildList() }
    }

    /// Debounce key: changes when the trimmed search text changes.
    private var searchQueryKey: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rebuildList() async {
        // Debounce keystrokes: wait briefly before issuing a new query.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled, let client = services.client else { return }
        let search = searchQueryKey.isEmpty ? nil : searchQueryKey
        let libraryID = libraryID
        // Cache only the unfiltered first page; search results are never cached.
        let cache: BrowseCache? = search == nil ? .shared : nil
        let cacheKey = search == nil ? "series-\(libraryID ?? "all")" : nil
        let newList = PaginatedList<KomgaSeries>(cache: cache, cacheKey: cacheKey) { page, size in
            try await client.series(libraryID: libraryID, search: search, page: page, size: size)
        }
        list = newList
    }
}
