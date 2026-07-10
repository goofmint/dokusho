import SwiftUI
import KomgaKit

/// A paginated, adaptive grid of series with cover thumbnails.
///
/// Reused by the library screen, collection detail, and search results. Column
/// count adapts to the horizontal size class (design §2.3 iPad support). Tapping
/// a cell pushes ``BrowseRoute/series(_:)``.
struct SeriesGrid: View {
    let list: PaginatedList<KomgaSeries>

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var columns: [GridItem] {
        let minWidth: CGFloat = horizontalSizeClass == .regular ? 160 : 110
        return [GridItem(.adaptive(minimum: minWidth), spacing: 16)]
    }

    var body: some View {
        Group {
            switch list.phase {
            case .idle, .loadingFirst:
                ProgressView().controlSize(.large)
            case let .failed(message):
                ErrorStateView(message: message) {
                    Task { await list.reload() }
                }
            case .loaded:
                if list.items.isEmpty {
                    ContentUnavailableView("シリーズがありません", systemImage: "books.vertical")
                } else {
                    grid
                }
            }
        }
        .task { await list.loadInitialIfNeeded() }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(list.items) { series in
                    NavigationLink(value: BrowseRoute.series(series)) {
                        SeriesCell(series: series)
                    }
                    .buttonStyle(.plain)
                    .task { await list.loadMoreIfNeeded(currentItem: series) }
                }
            }
            .padding(16)

            if list.isLoadingMore {
                ProgressView().padding()
            }
        }
        .refreshable { await list.reload() }
    }
}

/// A single series cover cell: thumbnail, title, and unread badge.
private struct SeriesCell: View {
    let series: KomgaSeries

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ThumbnailImageView(target: .series(id: series.id))
                .aspectRatio(0.7, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) {
                    if series.booksUnreadCount > 0 {
                        Text("\(series.booksUnreadCount)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.tint, in: Capsule())
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }

            Text(series.metadata.title.isEmpty ? series.name : series.metadata.title)
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(.primary)
        }
    }
}
