import SwiftUI
import SwiftData

/// Downloads management screen.
///
/// Lists downloaded and in-progress books with size/date, offers swipe-to-delete
/// and cancel, and shows the total downloaded size in the footer. Tapping a
/// completed book routes to a reader placeholder (wired in Phase 6.3 / 6.4).
///
/// Reads ``DownloadManager`` from the environment. The manager is the source of
/// truth for live state; the `DownloadedBook` records drive the list contents.
struct DownloadsView: View {
    @Environment(DownloadManager.self) private var downloadManager
    /// All persisted download records, kept live by SwiftData.
    @Query(sort: \DownloadedBook.title) private var records: [DownloadedBook]

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("ダウンロード")
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

    /// A downloaded book is tappable (navigates to a reader placeholder that
    /// Phase 6.3 / 6.4 will replace); in-progress and failed rows are not.
    @ViewBuilder
    private func row(for record: DownloadedBook) -> some View {
        let state = downloadManager.state(for: record.bookID)
        let rowContent = DownloadRow(
            record: record,
            state: state,
            onCancel: { downloadManager.cancel(bookID: record.bookID) }
        )
        if case .downloaded = state {
            NavigationLink {
                DownloadedBookReaderPlaceholder(record: record)
            } label: {
                rowContent
            }
        } else {
            rowContent
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

/// Temporary destination for a downloaded book. The real reader (Readium for
/// ePub, PDFKit for PDF) is wired in Phase 6.3 / 6.4.
private struct DownloadedBookReaderPlaceholder: View {
    let record: DownloadedBook

    var body: some View {
        ContentUnavailableView(
            record.title,
            systemImage: "book",
            description: Text("リーダーは今後のフェーズで実装されます。")
        )
        .navigationTitle(record.title)
        .navigationBarTitleDisplayMode(.inline)
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
