import SwiftUI
import SwiftData
import KomgaKit

/// Downloads management screen (top-level section).
///
/// Wraps ``DownloadsList`` in its own `NavigationStack` for use as a tab / sidebar
/// destination. The list itself is factored out so the Settings screen can push
/// it without nesting navigation stacks.
struct DownloadsView: View {
    var body: some View {
        NavigationStack {
            DownloadsList()
                .navigationTitle("ダウンロード")
        }
    }
}

/// The downloads list content: downloaded and in-progress books with size/date,
/// swipe-to-delete and cancel, total size in the footer, and offline opening.
///
/// Tapping a completed book reads its persisted `book.json` and presents the
/// reader full-screen; a missing sidecar surfaces an explicit error (no crash).
///
/// Reads ``DownloadManager`` from the environment. The manager is the source of
/// truth for live state; the `DownloadedBook` records drive the list contents.
struct DownloadsList: View {
    @Environment(DownloadManager.self) private var downloadManager
    /// All persisted download records, kept live by SwiftData.
    @Query(sort: \DownloadedBook.title) private var records: [DownloadedBook]

    /// The book whose reader is currently presented full-screen, if any.
    @State private var readingBook: KomgaBook?
    /// Set when a tapped record's `book.json` sidecar is missing/unreadable.
    @State private var metadataError: String?

    var body: some View {
        content
            .fullScreenCover(item: $readingBook) { book in
                NavigationStack {
                    ReaderRootView(book: book)
                }
            }
            .alert(
                "この本を開けません",
                isPresented: Binding(
                    get: { metadataError != nil },
                    set: { if !$0 { metadataError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(metadataError ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        if visibleRecords.isEmpty {
            ContentUnavailableView(
                "ダウンロード済みのブックはありません",
                systemImage: "arrow.down.circle",
                description: Text("ブックの詳細画面からダウンロードすると、ここに表示されます。")
            )
        } else {
            List {
                Section {
                    ForEach(visibleRecords, id: \.bookID) { record in
                        row(for: record)
                    }
                    .onDelete(perform: deleteRecords)
                } footer: {
                    Text("合計サイズ: \(formattedTotalSize)")
                }
            }
        }
    }

    /// A downloaded book is tappable and opens the offline reader; in-progress
    /// and failed rows are not. Opening reads the persisted `book.json` sidecar;
    /// if it is missing the tap surfaces an explicit error instead of crashing.
    @ViewBuilder
    private func row(for record: DownloadedBook) -> some View {
        let state = downloadManager.state(for: record.bookID)
        let rowContent = DownloadRow(
            record: record,
            state: state,
            onCancel: { downloadManager.cancel(bookID: record.bookID) }
        )
        if case .downloaded = state {
            Button {
                open(record: record)
            } label: {
                rowContent
            }
            .buttonStyle(.plain)
        } else {
            rowContent
        }
    }

    /// Resolves the offline book metadata and presents the reader, or surfaces a
    /// Japanese error when the sidecar is unavailable.
    private func open(record: DownloadedBook) {
        if let book = downloadManager.localBook(for: record.bookID) {
            readingBook = book
        } else {
            metadataError = "この本のメタデータ（book.json）が見つかりません。もう一度ダウンロードしてください。"
        }
    }

    /// Records worth showing: fully downloaded or currently in progress. A
    /// record reset to `notDownloaded` during reconciliation is hidden.
    private var visibleRecords: [DownloadedBook] {
        records.filter { record in
            switch downloadManager.state(for: record.bookID) {
            case .downloaded, .downloading, .failed:
                return true
            case .notDownloaded:
                return false
            }
        }
    }

    private var formattedTotalSize: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(downloadManager.totalDownloadedSize()),
            countStyle: .file
        )
    }

    private func deleteRecords(at offsets: IndexSet) {
        for index in offsets {
            let record = visibleRecords[index]
            try? downloadManager.delete(bookID: record.bookID)
        }
    }
}

/// A single row in the downloads list.
private struct DownloadRow: View {
    let record: DownloadedBook
    let state: DownloadState
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(record.seriesTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    FormatBadge(mediaProfile: record.mediaProfile)
                    detailText
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            trailing
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var detailText: some View {
        switch state {
        case .downloaded:
            HStack(spacing: 8) {
                Text(formattedSize)
                if let date = record.downloadedAt {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                }
            }
        case let .downloading(progress):
            Text("\(Int(progress * 100))%")
        case .failed:
            Text("ダウンロード失敗")
                .foregroundStyle(.red)
        case .notDownloaded:
            EmptyView()
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .downloaded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .downloading(progress):
            HStack(spacing: 12) {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                Button(role: .cancel, action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("キャンセル")
            }
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .notDownloaded:
            EmptyView()
        }
    }

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(record.totalBytes), countStyle: .file)
    }
}

/// Small pill showing the book format (ePub / PDF).
private struct FormatBadge: View {
    let mediaProfile: String

    private var label: String {
        switch mediaProfile.uppercased() {
        case "PDF": return "PDF"
        case "EPUB": return "ePub"
        default: return mediaProfile
        }
    }

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
            .foregroundStyle(Color.accentColor)
    }
}
