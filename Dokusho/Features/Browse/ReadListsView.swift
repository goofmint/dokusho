import SwiftUI
import KomgaKit

/// The list of read lists. Tapping one pushes ``BrowseRoute/readList(_:)``,
/// which shows the read list's book list.
struct ReadListsView: View {
    @Environment(AppServices.self) private var services
    @State private var list: PaginatedList<KomgaReadList>?

    var body: some View {
        NavigationStack {
            Group {
                if let list {
                    ReadListListContent(list: list)
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .navigationTitle("リードリスト")
            .browseDestinations()
            .task { await buildIfNeeded() }
        }
    }

    private func buildIfNeeded() async {
        guard list == nil, let client = services.client else { return }
        list = PaginatedList<KomgaReadList>(cache: .shared, cacheKey: "readlists") { page, size in
            try await client.readLists(page: page, size: size)
        }
    }
}

/// Renders the paginated read-list rows with their thumbnails.
private struct ReadListListContent: View {
    let list: PaginatedList<KomgaReadList>

    var body: some View {
        Group {
            switch list.phase {
            case .idle, .loadingFirst:
                ProgressView().controlSize(.large)
            case let .failed(message):
                ErrorStateView(message: message) { Task { await list.reload() } }
            case .loaded:
                if list.items.isEmpty {
                    ContentUnavailableView("リードリストがありません", systemImage: "list.bullet.rectangle")
                } else {
                    rows
                }
            }
        }
        .task { await list.loadInitialIfNeeded() }
    }

    private var rows: some View {
        List {
            ForEach(list.items) { readList in
                NavigationLink(value: BrowseRoute.readList(readList)) {
                    HStack(spacing: 12) {
                        ThumbnailImageView(target: .readList(id: readList.id))
                            .aspectRatio(0.7, contentMode: .fit)
                            .frame(width: 48, height: 68)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(readList.name).font(.body).lineLimit(2)
                            Text("\(readList.bookIds.count)冊")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .task { await list.loadMoreIfNeeded(currentItem: readList) }
            }
            if list.isLoadingMore {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .listStyle(.plain)
        .refreshable { await list.reload() }
    }
}

/// The book list within a read list.
struct ReadListDetailView: View {
    let readList: KomgaReadList

    @Environment(AppServices.self) private var services
    @State private var list: PaginatedList<KomgaBook>?

    var body: some View {
        Group {
            if let list {
                BookList(list: list)
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .navigationTitle(readList.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await buildIfNeeded() }
    }

    private func buildIfNeeded() async {
        guard list == nil, let client = services.client else { return }
        let id = readList.id
        list = PaginatedList<KomgaBook> { page, size in
            try await client.readListBooks(id: id, page: page, size: size)
        }
    }
}
