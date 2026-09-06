import SwiftUI
import KomgaKit

/// The media profiles this app can open (design §0: ePub/PDF only).
enum SupportedMediaProfile {
    static func isSupported(_ profile: String) -> Bool {
        profile == "EPUB" || profile == "PDF"
    }
}

/// A paginated list of books with cover thumbnails and read progress.
///
/// Reused by series detail and read-list detail. Supported books push
/// ``BrowseRoute/book(_:)``; unsupported formats are grayed out and inert.
struct BookList: View {
    let list: PaginatedList<KomgaBook>
    var selectedIDs: Binding<Set<String>>? = nil

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
                    ContentUnavailableView("ブックがありません", systemImage: "book")
                } else {
                    listView
                }
            }
        }
        .task { await list.loadInitialIfNeeded() }
    }

    private var listView: some View {
        List {
            ForEach(list.items) { book in
                BookRow(book: book, selectedIDs: selectedIDs)
                    .task { await list.loadMoreIfNeeded(currentItem: book) }
            }
            if list.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await list.reload() }
    }
}

/// A single book row. Navigates to the book detail when the format is
/// supported; otherwise renders grayed out with a 非対応フォーマット label.
struct BookRow: View {
    let book: KomgaBook
    var selectedIDs: Binding<Set<String>>? = nil
    @Environment(DownloadManager.self) private var downloadManager

    private var isSupported: Bool { SupportedMediaProfile.isSupported(book.media.mediaProfile) }

    var body: some View {
        if let selectedIDs {
            Button {
                if selectedIDs.wrappedValue.contains(book.id) {
                    selectedIDs.wrappedValue.remove(book.id)
                } else {
                    selectedIDs.wrappedValue.insert(book.id)
                }
            } label: {
                HStack {
                    Image(systemName: selectedIDs.wrappedValue.contains(book.id) ? "checkmark.circle.fill" : "circle")
                    content
                }
            }
            .buttonStyle(.plain)
            .disabled(!downloadManager.canDownload(book))
            .accessibilityValue(selectedIDs.wrappedValue.contains(book.id) ? "選択済み" : "未選択")
        } else if isSupported {
            NavigationLink(value: BrowseRoute.book(book)) {
                content
            }
        } else {
            content
                .foregroundStyle(.secondary)
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            ThumbnailImageView(target: .book(id: book.id))
                .aspectRatio(0.7, contentMode: .fit)
                .frame(width: 48, height: 68)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .opacity(isSupported ? 1 : 0.5)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle)
                    .font(.body)
                    .lineLimit(2)

                if !isSupported {
                    Text("非対応フォーマット")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    BookProgressLabel(book: book)
                    downloadStatus
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var displayTitle: String {
        book.metadata.title.isEmpty ? book.name : book.metadata.title
    }

    /// Shows per-book transfer state during and after a batch download.
    @ViewBuilder
    private var downloadStatus: some View {
        switch downloadManager.state(for: book.id) {
        case .notDownloaded:
            EmptyView()
        case let .downloading(progress):
            ProgressView(value: progress) {
                Text("ダウンロード中").font(.caption)
            }
        case .downloaded:
            Label("ダウンロード済み", systemImage: "arrow.down.circle.fill")
                .font(.caption).foregroundStyle(.secondary)
        case let .failed(error):
            Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.red)
        }
    }
}

/// A compact read-progress descriptor for a book (unread / reading n/total /
/// completed), derived from ``KomgaReadProgress`` and the page count.
struct BookProgressLabel: View {
    let book: KomgaBook

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var pagesCount: Int { book.media.pagesCount }

    private var symbol: String {
        guard let progress = book.readProgress else { return "circle" }
        return progress.completed ? "checkmark.circle.fill" : "book.circle"
    }

    private var text: String {
        guard let progress = book.readProgress else { return "未読" }
        if progress.completed { return "読了" }
        return "読書中 \(progress.page)/\(pagesCount)"
    }
}
