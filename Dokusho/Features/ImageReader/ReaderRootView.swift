import SwiftUI
import SwiftData
import KomgaKit

/// Entry point for the full-screen online and offline reader presentations.
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
///
/// Resume position is resolved once via ``ResumeProgressResolver`` before any
/// reader is built. Local progress wins by default. When the cloud page is
/// newer and differs, a confirmation dialog asks whether to move.
struct ReaderRootView: View {
    let book: KomgaBook

    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext

    /// Full Phase-1 resolution (adopted page + conflict info) for the confirm UI.
    @State private var resumeResult: ResumeProgressResult?
    /// 1-based page passed as `initialPage` once resolution (and any confirm) finishes.
    @State private var confirmedPage: Int?
    /// True once a reader may be constructed (aligned immediately, or after the dialog).
    @State private var isResumeReady = false
    @State private var showResumeConflictDialog = false

    private var profile: String {
        book.media.mediaProfile.uppercased()
    }

    var body: some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            .task { resolveResumeIfNeeded() }
            .confirmationDialog(
                "続きの位置が異なります",
                isPresented: $showResumeConflictDialog,
                titleVisibility: .visible
            ) {
                Button("クラウドの位置で開く") { adoptCloudPage() }
                Button("この端末の位置で開く", role: .cancel) { adoptLocalPage() }
            } message: {
                Text(resumeConflictMessage)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch profile {
        case "PDF":
            pdfContent
        case "EPUB":
            epubContent
        default:
            unsupported
        }
    }

    // MARK: - PDF

    @ViewBuilder
    private var pdfContent: some View {
        if !canPresentPDFReader {
            disconnected
        } else if isResumeReady {
            pdfReader
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var pdfReader: some View {
        if let fileURL = services.downloadManager?.localURL(for: book.id) {
            // Downloaded: rasterize the local PDF through the image reader, so
            // spreads / RTL / tap zones behave identically to streaming.
            LocalPdfImageReader(
                book: book,
                fileURL: fileURL,
                client: services.client,
                initialPage: confirmedPage,
                onProgress: recordProgress
            )
        } else if let imageLoader = services.imageLoader, let client = services.client {
            ImageReaderScreen(
                book: book,
                source: StreamingPageSource(loader: imageLoader, bookID: book.id),
                client: client,
                initialPage: confirmedPage,
                onProgress: recordProgress
            )
        } else {
            disconnected
        }
    }

    // MARK: - EPUB

    @ViewBuilder
    private var epubContent: some View {
        if services.downloadManager?.localURL(for: book.id) == nil {
            downloadPrompt
        } else if isResumeReady {
            epubReader
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var epubReader: some View {
        if let fileURL = services.downloadManager?.localURL(for: book.id) {
            EpubReaderContainer(
                book: book,
                fileURL: fileURL,
                client: services.client,
                initialPage: confirmedPage,
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

    private var canPresentPDFReader: Bool {
        services.downloadManager?.localURL(for: book.id) != nil
            || (services.imageLoader != nil && services.client != nil)
    }

    /// True when a reader will actually be built and therefore needs a resume page.
    private var shouldResolveResume: Bool {
        switch profile {
        case "PDF": return canPresentPDFReader
        case "EPUB": return services.downloadManager?.localURL(for: book.id) != nil
        default: return false
        }
    }

    private var resumeConflictMessage: String {
        guard case let .conflict(localPage, cloudPage) = resumeResult else {
            return "この端末とクラウドで続きの位置が異なります。"
        }
        return "この端末では \(localPage) ページ、クラウドでは \(cloudPage) ページです。クラウドの位置へ移動しますか？"
    }

    /// Fetches local + server progress and applies ``ResumeProgressResolver``.
    ///
    /// Aligned results build the reader immediately. A conflict holds construction
    /// and presents the confirmation dialog; the default (cancel) keeps local.
    private func resolveResumeIfNeeded() {
        guard !isResumeReady, !showResumeConflictDialog else { return }
        guard shouldResolveResume else { return }

        let localState = fetchLocalReadingState()
        let result = ResumeProgressResolver.resolve(
            localPage: localState?.lastPage,
            localUpdatedAt: localState?.updatedAt,
            serverPage: book.readProgress?.page,
            serverReadDate: book.readProgress?.readDate
        )
        resumeResult = result

        switch result {
        case .aligned(let page):
            confirmedPage = page
            isResumeReady = true
        case .conflict:
            showResumeConflictDialog = true
        }
    }

    private func adoptLocalPage() {
        confirmedPage = resumeResult?.adoptedPage
        isResumeReady = true
    }

    private func adoptCloudPage() {
        if case let .conflict(_, cloudPage) = resumeResult {
            confirmedPage = cloudPage
        } else {
            confirmedPage = resumeResult?.adoptedPage
        }
        isResumeReady = true
    }

    private func fetchLocalReadingState() -> LocalReadingState? {
        let bookID = book.id
        let descriptor = FetchDescriptor<LocalReadingState>(
            predicate: #Predicate { $0.bookID == bookID }
        )
        return (try? modelContext.fetch(descriptor))?.first
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

/// Routes a downloaded ePub to the right reader.
///
/// Image-only ePubs (Calibre/manga packaging: every spine item wraps a single
/// page image) render terribly through Readium's reflowable path — their
/// publisher CSS pins pages to fixed pixel sizes, so pages show small and
/// spreads never engage. Those books are detected by
/// ``EpubImagePageSource/make(fileURL:)`` and shown through the app's own
/// image reader (full-screen fit, landscape spreads, RTL from the spine's
/// page-progression-direction). Text ePubs fall back to the Readium reader.
struct EpubReaderContainer: View {
    let book: KomgaBook
    let fileURL: URL
    let client: KomgaClient?
    /// Caller-resolved 1-based resume page (local vs. server progress).
    let initialPage: Int?
    let onProgress: @MainActor (Int, Bool) -> Void

    private enum Phase {
        case deciding
        case imageBook(EpubImagePageSource)
        case reflowable
    }

    @State private var phase: Phase = .deciding

    var body: some View {
        content
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .deciding:
            ProgressView("ePub を確認しています…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task {
                    // Detection parses the spine off the main actor.
                    let source = await Task.detached(priority: .userInitiated) {
                        await EpubImagePageSource.make(fileURL: fileURL)
                    }.value
                    if let source {
                        phase = .imageBook(source)
                    } else {
                        phase = .reflowable
                    }
                }
        case let .imageBook(source):
            ImageReaderScreen(
                book: book,
                source: source,
                client: client,
                initialPage: initialPage,
                initialDirectionHint: source.prefersRightToLeft.map {
                    $0 ? .rightToLeft : .leftToRight
                },
                onProgress: onProgress
            )
        case .reflowable:
            EpubReaderScreen(
                book: book,
                fileURL: fileURL,
                initialPage: initialPage,
                onProgress: onProgress
            )
        }
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
            // Presented inside a navigation stack; hide the nav/tab bars so no
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
