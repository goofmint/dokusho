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
    /// Tap callback used to toggle the HUD. Reports the tap's vertical position
    /// as a fraction of the view height (0 = top, 1 = bottom) so the caller can
    /// distinguish a bottom-strip tap from a center tap. PDFKit's `PDFView`
    /// consumes touches, so a UIKit tap recognizer (below) is the reliable
    /// path — a SwiftUI `.onTapGesture` on the wrapper never fires.
    let onTap: (_ verticalFraction: CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPageChanged: onPageChanged, onTap: onTap)
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
        context.coordinator.installTapRecognizer(on: pdfView)
        context.coordinator.applySpread(to: pdfView)

        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        if pdfView.displaysRTL != displaysRTL {
            context.coordinator.applyReadingDirection(displaysRTL, to: pdfView)
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
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private let onPageChanged: (Int) -> Void
        private let onTap: (CGFloat) -> Void
        private weak var pdfView: PDFView?
        private var observer: NSObjectProtocol?
        private var lastReportedPage: Int?
        /// While `true`, transient `PDFViewPageChanged` notifications fired during
        /// a reading-direction relayout are ignored so progress isn't corrupted.
        private var suppressesPageChanges = false

        init(onPageChanged: @escaping (Int) -> Void, onTap: @escaping (CGFloat) -> Void) {
            self.onPageChanged = onPageChanged
            self.onTap = onTap
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

        /// Installs a single-tap recognizer that toggles the HUD. It runs
        /// alongside PDFKit's own gestures (swipe paging, pinch zoom, link taps)
        /// and defers to any internal double-tap recognizer so a zoom double-tap
        /// is never mistaken for a HUD toggle.
        func installTapRecognizer(on pdfView: PDFView) {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            recognizer.numberOfTapsRequired = 1
            recognizer.delegate = self

            // Require PDFKit's internal double-tap recognizers to fail first, so
            // our single tap only fires when it is not the start of a double tap.
            for existing in doubleTapRecognizers(in: pdfView) {
                recognizer.require(toFail: existing)
            }

            pdfView.addGestureRecognizer(recognizer)
        }

        /// Collects `UITapGestureRecognizer`s with `numberOfTapsRequired == 2`
        /// on the PDFView and its subviews (PDFKit hosts them on the internal
        /// scroll/content views).
        private func doubleTapRecognizers(in root: UIView) -> [UITapGestureRecognizer] {
            var found: [UITapGestureRecognizer] = []
            var stack: [UIView] = [root]
            while let view = stack.popLast() {
                for recognizer in view.gestureRecognizers ?? [] {
                    if let tap = recognizer as? UITapGestureRecognizer,
                       tap.numberOfTapsRequired == 2 {
                        found.append(tap)
                    }
                }
                stack.append(contentsOf: view.subviews)
            }
            return found
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let pdfView else { return }
            let height = pdfView.bounds.height
            guard height > 0 else {
                onTap(0)
                return
            }
            let location = recognizer.location(in: pdfView)
            let fraction = min(max(location.y / height, 0), 1)
            onTap(fraction)
        }

        // Run our tap alongside PDFKit's own recognizers rather than blocking them.
        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        /// Re-applies the reading direction and re-lays out the live view.
        /// PDFKit does not re-layout `usePageViewController(true)` on a bare
        /// `displaysRTL` change, so the document is reassigned to force it, with
        /// the current page captured and restored and page-changed notifications
        /// suppressed across the swap.
        func applyReadingDirection(_ displaysRTL: Bool, to pdfView: PDFView) {
            let currentPage = pdfView.currentPage
            suppressesPageChanges = true
            defer { suppressesPageChanges = false }

            pdfView.displaysRTL = displaysRTL
            let document = pdfView.document
            pdfView.document = nil
            pdfView.document = document
            pdfView.usePageViewController(true, withViewOptions: nil)

            if let currentPage {
                pdfView.go(to: currentPage)
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
            guard !suppressesPageChanges else { return }
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
