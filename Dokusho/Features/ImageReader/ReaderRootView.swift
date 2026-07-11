import SwiftUI
import SwiftData
import KomgaKit

/// Entry point for the reader, registered for ``ReaderDestination``.
///
/// Dispatches to the correct reader based on the book's `mediaProfile` and
/// whether it is downloaded:
///
/// | Profile | Downloaded | Screen |
/// |---|---|---|
/// | PDF | yes | ``ImageReaderScreen`` + ``LocalPdfPageSource`` (local rasterizing) |
/// | PDF | no  | ``ImageReaderScreen`` + ``StreamingPageSource`` (streaming) |
/// | EPUB | yes | `EpubReaderScreen` (integration point) |
/// | EPUB | no  | download prompt |
/// | other | — | unsupported message (should be unreachable) |
///
/// Progress from every reader flows through ``AppServices/progressSyncer`` via a
/// single `onProgress` closure whose shape is `(Int, Bool)` = (1-based page,
/// completed).
struct ReaderRootView: View {
    let book: KomgaBook

    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext

    private var profile: String {
        book.media.mediaProfile.uppercased()
    }

    var body: some View {
        content
            .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var content: some View {
        switch profile {
        case "PDF":
            pdfReader
        case "EPUB":
            epubReader
        default:
            unsupported
        }
    }

    // MARK: - PDF

    @ViewBuilder
    private var pdfReader: some View {
        if let fileURL = services.downloadManager?.localURL(for: book.id) {
            // Downloaded: rasterize the local PDF through the image reader, so
            // spreads / RTL / tap zones behave identically to streaming.
            LocalPdfImageReader(
                book: book,
                fileURL: fileURL,
                client: services.client,
                initialPage: effectiveResumePage(),
                onProgress: recordProgress
            )
        } else if let imageLoader = services.imageLoader, let client = services.client {
            ImageReaderScreen(
                book: book,
                source: StreamingPageSource(loader: imageLoader, bookID: book.id),
                client: client,
                onProgress: recordProgress
            )
        } else {
            disconnected
        }
    }

    // MARK: - EPUB

    @ViewBuilder
    private var epubReader: some View {
        if let fileURL = services.downloadManager?.localURL(for: book.id) {
            EpubReaderScreen(
                book: book,
                fileURL: fileURL,
                initialPage: effectiveResumePage(),
                onProgress: recordProgress
            )
        } else {
            downloadPrompt
        }
    }

    // MARK: - Sub-screens

    private var downloadPrompt: some View {
        DownloadPromptView(book: book)
    }

    private var unsupported: some View {
        ContentUnavailableView {
            Label("このフォーマットは非対応です", systemImage: "xmark.octagon")
        } description: {
            Text("「\(profile)」形式は閲覧に対応していません。")
        }
        .navigationTitle("読む")
    }

    private var disconnected: some View {
        ContentUnavailableView {
            Label("接続されていません", systemImage: "wifi.slash")
        } description: {
            Text("サーバーに接続してから再度お試しください。")
        }
        .navigationTitle("読む")
    }

    // MARK: - Resume position

    /// Computes the 1-based page a downloaded PDF/ePub reader should resume at.
    ///
    /// The `book.readProgress` snapshot is stale (captured at list-fetch time, or
    /// frozen at download time for books opened from the persisted sidecar), so it
    /// alone would resume at an old page. ``LocalReadingState`` is written on every
    /// page turn and is the local source of truth. Prefer it when it is newer than
    /// the server snapshot (or when there is no server snapshot); otherwise fall
    /// back to the server page. Returns `nil` when neither source is available, so
    /// the reader keeps its current book-derived behavior.
    private func effectiveResumePage() -> Int? {
        let bookID = book.id
        let descriptor = FetchDescriptor<LocalReadingState>(
            predicate: #Predicate { $0.bookID == bookID }
        )
        let localState = (try? modelContext.fetch(descriptor))?.first

        if let localState,
           book.readProgress == nil || localState.updatedAt > (book.readProgress?.readDate ?? .distantPast) {
            return localState.lastPage
        }
        return book.readProgress?.page
    }

    // MARK: - Progress

    private func recordProgress(page: Int, completed: Bool) {
        services.progressSyncer?.recordProgress(
            bookID: book.id,
            page: page,
            completed: completed
        )
    }
}

/// Opens a downloaded PDF exactly once (in `.task`, cached in `@State`, so the
/// document is not re-parsed on every render) and routes it through the image
/// reader via ``LocalPdfPageSource``. A file that cannot be opened shows an
/// explicit Japanese error screen — never a blank view, never a silent fallback.
private struct LocalPdfImageReader: View {
    let book: KomgaBook
    let fileURL: URL
    let client: KomgaClient?
    /// Caller-resolved 1-based resume page (local vs. server progress).
    let initialPage: Int?
    let onProgress: @MainActor (Int, Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case opening
        case ready(LocalPdfPageSource)
        case failed
    }

    @State private var phase: Phase = .opening

    var body: some View {
        content
            // Pushed via `navigationDestination`; hide the nav/tab bars so no
            // empty header area pushes the content down. The reader's own HUD
            // (or the error screen's button) handles dismissal.
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .opening:
            ProgressView("PDF を開いています…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task {
                    // PDFDocument parsing can be slow; build the source off the
                    // main actor and update the phase back on it.
                    let source = await Task.detached(priority: .userInitiated) {
                        LocalPdfPageSource(fileURL: fileURL)
                    }.value
                    if let source {
                        phase = .ready(source)
                    } else {
                        phase = .failed
                    }
                }
        case let .ready(source):
            ImageReaderScreen(
                book: book,
                source: source,
                client: client,
                initialPage: initialPage,
                onProgress: onProgress
            )
        case .failed:
            LocalPdfErrorView(onClose: { dismiss() })
        }
    }
}

/// Full-screen error state for a local PDF that could not be opened. The user
/// is told what happened and offered a way out.
private struct LocalPdfErrorView: View {
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)

                Text("PDFを開けませんでした")
                    .font(.headline)

                Text("ファイルが見つからないか、破損している可能性があります。ダウンロードし直してからもう一度お試しください。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Button("閉じる", action: onClose)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
            }
        }
    }
}

/// Shown for an ePub that has not been downloaded: ePub is read offline only, so
/// the user must download it first.
private struct DownloadPromptView: View {
    let book: KomgaBook
    @Environment(AppServices.self) private var services

    @State private var downloadError: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("この本はダウンロード後に閲覧できます")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("ePub はオフライン用にダウンロードしてから読みます。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                startDownload()
            } label: {
                Label("ダウンロード", systemImage: "arrow.down")
                    .frame(maxWidth: 260)
            }
            .buttonStyle(.borderedProminent)

            if let downloadError {
                Text(downloadError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .navigationTitle("読む")
    }

    private func startDownload() {
        downloadError = nil
        guard let downloadManager = services.downloadManager else {
            downloadError = "サーバーに接続していないためダウンロードできません。"
            return
        }
        do {
            try downloadManager.download(book: book)
        } catch {
            downloadError = error.localizedDescription
        }
    }
}
