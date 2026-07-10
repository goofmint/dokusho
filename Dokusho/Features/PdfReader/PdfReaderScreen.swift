import SwiftUI
import PDFKit
import KomgaKit

/// The downloaded-PDF reader screen (Task 6.4).
///
/// Renders a locally downloaded `.pdf` file with PDFKit. Streaming (undownloaded)
/// PDFs are handled by the image reader elsewhere; this screen only deals with the
/// on-device file. Progress is reported exclusively through ``onProgress`` so the
/// screen stays free of any dependency on `AppServices` / `DownloadManager` /
/// `ReadProgressSyncer`.
///
/// - Note: The reading-direction toggle is session-only. There is no per-book
///   persistence: reopening the book always starts from the document default
///   (LTR unless the PDF declares RTL). Persisting the override is out of scope
///   for Task 6.4.
struct PdfReaderScreen: View {
    private let book: KomgaBook
    private let fileURL: URL
    private let onProgress: @MainActor (Int, Bool) -> Void

    init(
        book: KomgaBook,
        fileURL: URL,
        onProgress: @escaping @MainActor (Int, Bool) -> Void
    ) {
        self.book = book
        self.fileURL = fileURL
        self.onProgress = onProgress
    }

    var body: some View {
        PdfReaderContentView(
            book: book,
            fileURL: fileURL,
            onProgress: onProgress
        )
    }
}

/// Loads the PDF document once and switches between the reader and an error
/// screen. Keeping the load here (rather than inside the reader body) avoids
/// re-parsing the document on every SwiftUI re-render.
private struct PdfReaderContentView: View {
    private let book: KomgaBook
    private let onProgress: @MainActor (Int, Bool) -> Void

    /// `nil` means the document could not be opened (missing file / corrupt PDF).
    private let document: PDFDocument?

    @Environment(\.dismiss) private var dismiss

    init(
        book: KomgaBook,
        fileURL: URL,
        onProgress: @escaping @MainActor (Int, Bool) -> Void
    ) {
        self.book = book
        self.onProgress = onProgress

        // Fail fast when the file is missing, so we show the error screen
        // instead of letting PDFDocument spend time on a doomed parse.
        if FileManager.default.fileExists(atPath: fileURL.path) {
            self.document = PDFDocument(url: fileURL)
        } else {
            self.document = nil
        }
    }

    var body: some View {
        Group {
            if let document, document.pageCount > 0 {
                PdfReaderView(
                    book: book,
                    document: document,
                    onProgress: onProgress,
                    onClose: { dismiss() }
                )
            } else {
                PdfReaderErrorView(onClose: { dismiss() })
            }
        }
    }
}

/// Full-screen error state. Never a blank screen and never a silent fallback:
/// the user is told the file could not be opened and offered a way out.
private struct PdfReaderErrorView: View {
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
