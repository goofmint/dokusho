import UIKit
import PDFKit

/// Abstracts where the image reader gets its page bitmaps from.
///
/// Two implementations exist:
/// - ``StreamingPageSource``: the Komga `pages/{n}` API via ``PageImageLoader``
///   (un-downloaded books) — the reader's original path, unchanged.
/// - ``LocalPdfPageSource``: a downloaded PDF rasterized locally with PDFKit.
///
/// Page numbers are **1-based** everywhere (Komga convention). Failures throw;
/// there are no silent placeholder fallbacks.
protocol ReaderPageSource: Sendable {
    /// The authoritative page count, when the source itself knows it (a local
    /// `PDFDocument` does). `nil` means the caller should fall back to the
    /// book's server-side metadata.
    var pageCount: Int? { get }

    /// Returns the bitmap for a page (1-based), fetching/rendering and caching
    /// it as needed.
    func image(page: Int) async throws -> UIImage

    /// Warms the cache for upcoming pages without blocking the caller.
    func prefetch(pages: [Int]) async

    /// Cancels in-flight prefetches for the given pages.
    func cancelPrefetch(pages: [Int]) async
}

// MARK: - Streaming (Komga API)

/// Streams page images from the Komga API through the shared
/// ``PageImageLoader``. A thin adapter: every call forwards 1:1 to the loader
/// with the wrapped `bookID`, so behavior is identical to the reader's
/// original direct loader usage.
struct StreamingPageSource: ReaderPageSource {
    let loader: PageImageLoader
    let bookID: String

    /// Streaming relies on the book metadata for the page count.
    var pageCount: Int? { nil }

    func image(page: Int) async throws -> UIImage {
        try await loader.image(bookID: bookID, page: page)
    }

    func prefetch(pages: [Int]) async {
        await loader.prefetch(bookID: bookID, pages: pages)
    }

    func cancelPrefetch(pages: [Int]) async {
        await loader.cancelPrefetch(bookID: bookID, pages: pages)
    }
}

// MARK: - Local PDF

/// Rasterizes pages of a downloaded PDF for the image reader.
///
/// PDFKit is used **only as a renderer** — paging, zoom, spreads, RTL and tap
/// zones are all the image reader's own. Each page is rendered at high
/// resolution (up to ``LocalPdfPageSource/maxPixelDimension`` on its long
/// edge, so vector content stays sharp under the reader's pinch zoom) and kept
/// in a pixel-cost `NSCache`.
///
/// Rendering happens synchronously on the actor, which serializes concurrent
/// requests for the same page: the second caller finds the cache already
/// populated. Prefetch requests run as child tasks that are tracked per page
/// so they can be cancelled when the reader moves away or is dismissed.
actor LocalPdfPageSource: ReaderPageSource {
    /// Unrecoverable per-page failures, surfaced to the reader's error UI.
    enum PdfPageError: Error {
        /// The document has no page at the requested (1-based) number.
        case pageMissing(Int)
        /// The page exists but has a degenerate (empty) media box.
        case renderFailed(Int)
    }

    /// Authoritative page count from the opened `PDFDocument`.
    nonisolated let pageCount: Int?

    private let document: PDFDocument
    private let cache = NSCache<NSNumber, UIImage>()
    /// Live prefetch tasks keyed by page number, cancelled on leave/teardown.
    private var prefetchTasks: [Int: Task<Void, Never>] = [:]

    /// Long-edge pixel target for rendered pages. High enough that text stays
    /// crisp when zoomed, low enough to keep per-page memory bounded.
    private static let maxPixelDimension: CGFloat = 2600
    /// Memory budget in pixels (cost = pixel count, ~4 bytes each): ~100 MB.
    private static let memoryPixelBudget = 100 * 1024 * 1024 / 4

    /// Opens the PDF at `fileURL`. Fails (returns `nil`) when the file is
    /// missing, cannot be parsed, or has no pages — the caller shows an
    /// explicit error screen instead.
    init?(fileURL: URL) {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let document = PDFDocument(url: fileURL),
              document.pageCount > 0 else {
            return nil
        }
        self.document = document
        self.pageCount = document.pageCount
        cache.totalCostLimit = Self.memoryPixelBudget
    }

    func image(page: Int) async throws -> UIImage {
        let key = NSNumber(value: page)
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let pdfPage = document.page(at: page - 1) else {
            throw PdfPageError.pageMissing(page)
        }
        let image = try render(pdfPage, pageNumber: page)
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale)
        cache.setObject(image, forKey: key, cost: max(cost, 1))
        return image
    }

    func prefetch(pages: [Int]) {
        for page in pages {
            guard cache.object(forKey: NSNumber(value: page)) == nil,
                  prefetchTasks[page] == nil else {
                continue
            }
            prefetchTasks[page] = Task {
                defer { prefetchTasks[page] = nil }
                guard !Task.isCancelled else { return }
                do {
                    _ = try await image(page: page)
                } catch {
                    // A failed prefetch is intentionally dropped: the page is
                    // re-rendered on actual display, where a failure surfaces
                    // through the reader's per-page error UI.
                }
            }
        }
    }

    func cancelPrefetch(pages: [Int]) {
        for page in pages {
            prefetchTasks[page]?.cancel()
            prefetchTasks[page] = nil
        }
    }

    /// Renders a page at up to ``maxPixelDimension`` on its long edge,
    /// preserving the media-box aspect ratio. `PDFPage.thumbnail` honors the
    /// page's rotation.
    private func render(_ pdfPage: PDFPage, pageNumber: Int) throws -> UIImage {
        let bounds = pdfPage.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else {
            throw PdfPageError.renderFailed(pageNumber)
        }
        let scale = Self.maxPixelDimension / max(bounds.width, bounds.height)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        return pdfPage.thumbnail(of: size, for: .mediaBox)
    }
}
