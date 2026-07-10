import SwiftUI
import KomgaKit

/// The list of collections. Tapping one pushes ``BrowseRoute/collection(_:)``,
/// which shows the collection's series grid.
struct CollectionsView: View {
    @Environment(AppServices.self) private var services
    @State private var list: PaginatedList<KomgaCollection>?

    var body: some View {
        NavigationStack {
            Group {
                if let list {
                    CollectionListContent(list: list)
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .navigationTitle("コレクション")
            .browseDestinations()
            .task { await buildIfNeeded() }
        }
    }

    private func buildIfNeeded() async {
        guard list == nil, let client = services.client else { return }
        list = PaginatedList<KomgaCollection>(cache: .shared, cacheKey: "collections") { page, size in
            try await client.collections(page: page, size: size)
        }
    }
}

/// Renders the paginated collection rows with their thumbnails.
private struct CollectionListContent: View {
    let list: PaginatedList<KomgaCollection>

    var body: some View {
        Group {
            switch list.phase {
            case .idle, .loadingFirst:
                ProgressView().controlSize(.large)
            case let .failed(message):
                ErrorStateView(message: message) { Task { await list.reload() } }
            case .loaded:
                if list.items.isEmpty {
                    ContentUnavailableView("コレクションがありません", systemImage: "square.stack")
                } else {
                    rows
                }
            }
        }
        .task { await list.loadInitialIfNeeded() }
    }

    private var rows: some View {
        List {
            ForEach(list.items) { collection in
                NavigationLink(value: BrowseRoute.collection(collection)) {
                    HStack(spacing: 12) {
                        ThumbnailImageView(target: .collection(id: collection.id))
                            .aspectRatio(0.7, contentMode: .fit)
                            .frame(width: 48, height: 68)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(collection.name).font(.body).lineLimit(2)
                            Text("\(collection.seriesIds.count)シリーズ")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .task { await list.loadMoreIfNeeded(currentItem: collection) }
            }
            if list.isLoadingMore {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .listStyle(.plain)
        .refreshable { await list.reload() }
    }
}

/// The series grid within a collection.
struct CollectionDetailView: View {
    let collection: KomgaCollection

    @Environment(AppServices.self) private var services
    @State private var list: PaginatedList<KomgaSeries>?

    var body: some View {
        Group {
            if let list {
                SeriesGrid(list: list)
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .navigationTitle(collection.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await buildIfNeeded() }
    }

    private func buildIfNeeded() async {
        guard list == nil, let client = services.client else { return }
        let id = collection.id
        list = PaginatedList<KomgaSeries> { page, size in
            try await client.collectionSeries(id: id, page: page, size: size)
        }
    }
}
