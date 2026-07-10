import SwiftUI
import KomgaKit

/// Book detail: cover, metadata, read progress, and the 読む / ダウンロード
/// actions. Only ePub/PDF books can be opened; other formats show a
/// 非対応フォーマット notice.
///
/// The 読む action pushes ``ReaderDestination/book(_:)``. The download row
/// reflects ``DownloadManager`` state live: idle → progress + cancel →
/// downloaded (with delete) / failed (with retry).
struct BookDetailView: View {
    /// The book as passed in from the list. May be stale (e.g. after reading);
    /// ``refreshedBook`` supersedes it once fetched.
    private let initialBook: KomgaBook

    init(book: KomgaBook) {
        initialBook = book
    }

    @Environment(AppServices.self) private var services
    @Environment(DownloadManager.self) private var downloadManager

    @State private var downloadActionError: String?
    /// Fresh copy fetched on appear so read progress reflects recent reading.
    @State private var refreshedBook: KomgaBook?

    private var book: KomgaBook { refreshedBook ?? initialBook }

    private var isSupported: Bool { SupportedMediaProfile.isSupported(book.media.mediaProfile) }

    private var displayTitle: String {
        book.metadata.title.isEmpty ? book.name : book.metadata.title
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                actions
                if !isSupported {
                    unsupportedNotice
                }
                metadataSection
            }
            .padding()
        }
        .navigationTitle(displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: initialBook.id) {
            await refreshBook()
        }
        .onAppear {
            // Re-fetch when returning from the reader so progress is current.
            Task { await refreshBook() }
        }
    }

    /// Fetches the latest book (read progress in particular). Failure keeps the
    /// last known copy — a stale label beats an error banner here, but it is
    /// still logged by the client layer.
    private func refreshBook() async {
        guard let client = services.client else { return }
        do {
            refreshedBook = try await client.book(id: initialBook.id)
        } catch {
            // Logged in KomgaClient; keep showing the last known state.
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            ThumbnailImageView(target: .book(id: book.id))
                .aspectRatio(0.7, contentMode: .fit)
                .frame(width: 120)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 8) {
                Text(displayTitle)
                    .font(.headline)
                Text(book.seriesTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                BookProgressLabel(book: book)
                Text(formatLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 12) {
            if isSupported {
                NavigationLink(value: ReaderDestination.book(book)) {
                    Label(readButtonTitle, systemImage: "book")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            if isSupported {
                downloadRow
            }

            if let downloadActionError {
                Label(downloadActionError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var downloadRow: some View {
        switch downloadManager.state(for: book.id) {
        case .notDownloaded:
            Button(action: startDownload) {
                Label("ダウンロード", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

        case .downloading(let progress):
            HStack(spacing: 12) {
                ProgressView(value: progress)
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("キャンセル", role: .cancel) {
                    downloadManager.cancel(bookID: book.id)
                }
                .font(.callout)
            }
            .padding(.vertical, 6)

        case .downloaded:
            HStack(spacing: 12) {
                Label("ダウンロード済み", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("削除", role: .destructive, action: deleteDownload)
                    .font(.callout)
            }
            .padding(.vertical, 6)

        case .failed(let error):
            HStack(spacing: 12) {
                Label("ダウンロード失敗", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .help(String(describing: error))
                Spacer()
                Button("再試行", action: startDownload)
                    .font(.callout)
            }
            .padding(.vertical, 6)
        }
    }

    private func startDownload() {
        downloadActionError = nil
        do {
            try downloadManager.download(book: book)
        } catch {
            downloadActionError = "ダウンロードを開始できませんでした: \(error.localizedDescription)"
        }
    }

    private func deleteDownload() {
        downloadActionError = nil
        do {
            try downloadManager.delete(bookID: book.id)
        } catch {
            downloadActionError = "削除できませんでした: \(error.localizedDescription)"
        }
    }

    private var unsupportedNotice: some View {
        Label("非対応フォーマットのため開けません（対応形式: ePub / PDF）", systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !book.metadata.summary.isEmpty {
                Text("概要").font(.headline)
                Text(book.metadata.summary)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            let authors = book.metadata.authors
            if !authors.isEmpty {
                Divider()
                Text("著者").font(.headline)
                ForEach(Array(authors.enumerated()), id: \.offset) { _, author in
                    HStack {
                        Text(author.name)
                        Spacer()
                        Text(author.role).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }

            Divider()
            LabeledContent("ページ数", value: "\(book.media.pagesCount)")
            LabeledContent("形式", value: book.media.mediaProfile)
            LabeledContent("サイズ", value: byteCountText(book.sizeBytes))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var readButtonTitle: String {
        if let progress = book.readProgress, !progress.completed, progress.page > 1 {
            return "続きから読む"
        }
        return "読む"
    }

    private var formatLabel: String {
        "\(book.media.mediaProfile) ・ \(book.media.pagesCount)ページ"
    }

    private func byteCountText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
