import SwiftUI

/// Shared, observable UI state for the downloaded-PDF reader.
///
/// Holds only session state — the current page, a page requested via the slider,
/// the reading direction (session toggle, not persisted), and the reader
/// background color. The `PDFView` wrapper reads `requestedPage` / `displaysRTL`
/// and writes back `currentPage`.
@MainActor
@Observable
final class PdfReaderState {
    /// Total number of pages in the document (>= 1 for a valid PDF).
    let pageCount: Int

    /// 1-based page currently shown, kept authoritative by PDFView notifications.
    var currentPage: Int = 1

    /// 1-based page the slider asks the PDFView to jump to. `nil` when no jump is
    /// pending; the wrapper resets it back to `nil` after applying.
    var requestedPage: Int?

    /// Right-to-left (right-bound) page turning. Toggled from the HUD only;
    /// intentionally not persisted per book for Task 6.4.
    var displaysRTL: Bool = false

    /// Reader background. Driven by the shared `readerBackground` setting: the
    /// hosting `PdfReaderView` writes this from `@AppStorage` on appear and on
    /// change, so the PDF reader honors the same choice as the image reader.
    var backgroundColor: Color = Color(.systemBackground)

    init(pageCount: Int) {
        self.pageCount = max(pageCount, 1)
    }

    func toggleReadingDirection() {
        displaysRTL.toggle()
    }
}
