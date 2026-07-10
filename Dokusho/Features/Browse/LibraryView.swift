import SwiftUI
import Observation
import KomgaKit

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

    func loadIfNeeded(client: KomgaClient?) async {
        guard case .idle = phase else { return }
        await reload(client: client)
    }

    func reload(client: KomgaClient?) async {
        guard let client else {
            phase = .failed("サーバーに接続していません。")
            return
        }
        phase = .loading
        do {
            libraries = try await client.libraries()
            phase = .loaded
        } catch is CancellationError {
        } catch {
            phase = .failed(ErrorMessage.text(for: error))
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
        let newList = PaginatedList<KomgaSeries> { page, size in
            try await client.series(libraryID: libraryID, search: search, page: page, size: size)
        }
        list = newList
    }
}
