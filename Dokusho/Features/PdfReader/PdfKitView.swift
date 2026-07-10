import SwiftUI
import PDFKit

/// SwiftUI wrapper around `PDFView` for downloaded PDFs.
///
/// PDFKit configuration:
/// - `usePageViewController(true, …)`: swipe-based paging without the page-curl
///   animation, giving a book-like feel with native gesture handling.
/// - `.singlePage` in portrait, `.twoUp` in landscape (spread / 見開き). Switching
///   is done live on trait/bounds changes.
/// - `autoScales = true` with `minScaleFactor`/`maxScaleFactor` so native pinch
///   zoom works within sensible bounds.
/// - `displaysRTL` follows the reading-direction toggle.
///
/// Page changes are surfaced through `PDFViewPageChangedNotification` and mapped
/// to a 1-based page number for the caller.
struct PdfKitView: UIViewRepresentable {
    let document: PDFDocument
    /// 0-based index the reader should open at (already range-clamped upstream).
    let initialPageIndex: Int
    let displaysRTL: Bool
    /// 1-based page requested via the slider. Reset to `nil` once applied.
    @Binding var requestedPage: Int?
    let onPageChanged: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPageChanged: onPageChanged)
    }

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = document
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .horizontal
        pdfView.usePageViewController(true, withViewOptions: nil)
        pdfView.autoScales = true
        pdfView.minScaleFactor = pdfView.scaleFactorForSizeToFit
        pdfView.maxScaleFactor = 5.0
        pdfView.displaysRTL = displaysRTL
        pdfView.backgroundColor = .clear

        // Open at the resume position.
        if let page = document.page(at: clampedIndex(for: document)) {
            pdfView.go(to: page)
        }

        context.coordinator.observe(pdfView)
        context.coordinator.applySpread(to: pdfView)

        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        if pdfView.displaysRTL != displaysRTL {
            pdfView.displaysRTL = displaysRTL
        }

        // Apply a pending slider jump, if any, without fighting user swipes.
        if let requested = requestedPage {
            context.coordinator.jump(to: requested, in: pdfView)
            // Clear the request so we don't re-apply it on the next render.
            DispatchQueue.main.async { requestedPage = nil }
        }

        // Re-evaluate single/two-up on layout changes (rotation, split view).
        context.coordinator.applySpread(to: pdfView)
    }

    static func dismantleUIView(_ pdfView: PDFView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    private func clampedIndex(for document: PDFDocument) -> Int {
        let count = document.pageCount
        guard count > 0 else { return 0 }
        return min(max(initialPageIndex, 0), count - 1)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject {
        private let onPageChanged: (Int) -> Void
        private weak var pdfView: PDFView?
        private var observer: NSObjectProtocol?
        private var lastReportedPage: Int?

        init(onPageChanged: @escaping (Int) -> Void) {
            self.onPageChanged = onPageChanged
        }

        func observe(_ pdfView: PDFView) {
            self.pdfView = pdfView
            observer = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged,
                object: pdfView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handlePageChanged()
                }
            }
        }

        func stopObserving() {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            observer = nil
            pdfView = nil
        }

        /// Switch between `.singlePage` (portrait) and `.twoUp` (landscape spread)
        /// based on the current bounds aspect ratio. Preserves the current page.
        func applySpread(to pdfView: PDFView) {
            let isLandscape = pdfView.bounds.width > pdfView.bounds.height
            let desired: PDFDisplayMode = isLandscape ? .twoUp : .singlePage
            guard pdfView.displayMode != desired else { return }

            let current = pdfView.currentPage
            pdfView.displayMode = desired
            if let current {
                pdfView.go(to: current)
            }
        }

        /// Jump to a 1-based page requested by the slider, clamped to range.
        func jump(to oneBasedPage: Int, in pdfView: PDFView) {
            guard let document = pdfView.document else { return }
            let count = document.pageCount
            guard count > 0 else { return }
            let index = min(max(oneBasedPage - 1, 0), count - 1)
            guard let page = document.page(at: index) else { return }
            pdfView.go(to: page)
        }

        private func handlePageChanged() {
            guard let pdfView,
                  let document = pdfView.document,
                  let current = pdfView.currentPage else { return }

            let index = document.index(for: current)
            let oneBased = index + 1
            guard oneBased != lastReportedPage else { return }
            lastReportedPage = oneBased
            onPageChanged(oneBased)
        }
    }
}
