import Foundation
import UIKit
import os
import ReadiumShared
import ReadiumStreamer

/// A ``ReaderPageSource`` for **image-only ePubs** (Calibre/manga-style books
/// where every spine item is an XHTML wrapping a single page image).
///
/// Why this exists: such books are *not* declared fixed-layout, so Readium
/// renders them as reflowable text — and their publisher CSS typically pins
/// each image to a fixed pixel size (e.g. `width: 764px; height: 1200px`),
/// which ignores the screen entirely and shows a small page lost in margins.
/// Instead of fighting that rendering, the images are extracted and shown
/// through the app's own image reader, which already handles full-screen
/// fitting, landscape spreads, RTL and zoom.
///
/// ``make(fileURL:)`` returns `nil` when the book is *not* image-only (real
/// reflowable text); the caller then falls back to the Readium reader.
actor EpubImagePageSource: ReaderPageSource {
    /// Unrecoverable failures, surfaced to the reader's per-page error UI.
    enum EpubImageError: Error {
        case pageMissing(Int)
        case resourceMissing(String)
        case decodeFailed(String)
        case publicationOpenFailed
    }

    /// Authoritative page count (the number of extracted page images).
    nonisolated let pageCount: Int?

    /// Whether the publication declares right-to-left reading (右綴じ).
    /// `nil` when the publication doesn't say (auto).
    nonisolated let prefersRightToLeft: Bool?

    private let fileURL: URL
    /// Ordered, container-root-relative hrefs of each page image (1-based
    /// page n ↔ index n-1).
    private let imageHrefs: [String]

    /// Lazily opened publication, confined to this actor. `make(fileURL:)`
    /// uses its own short-lived instance for detection, so the `Publication`
    /// (non-Sendable) never crosses an isolation boundary.
    private var publication: Publication?

    /// Decoded page cache (cost = pixel count; ~100 MB of RGBA).
    private let cache = NSCache<NSNumber, UIImage>()

    /// In-flight prefetch tasks by 1-based page number.
    private var prefetchTasks: [Int: Task<Void, Never>] = [:]

    private static let logger = Logger(
        subsystem: "jp.moongift.dokusho",
        category: "EpubImagePageSource"
    )

    private init(fileURL: URL, imageHrefs: [String], prefersRightToLeft: Bool?) {
        self.fileURL = fileURL
        self.imageHrefs = imageHrefs
        self.prefersRightToLeft = prefersRightToLeft
        pageCount = imageHrefs.count
        cache.totalCostLimit = 25_000_000 // pixels
    }

    // MARK: - Factory / detection

    /// Opens the ePub and, when every reading-order item is a single-image
    /// page, returns a source serving those images. Returns `nil` for
    /// text/reflowable books (the caller falls back to the Readium reader).
    static func make(fileURL: URL) async -> EpubImagePageSource? {
        guard let publication = await open(fileURL: fileURL) else { return nil }

        var hrefs: [String] = []
        for link in publication.readingOrder {
            guard let resource = publication.get(link) else { return nil }
            guard case let .success(data) = await resource.read() else { return nil }
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            guard let src = singleImageSource(in: html) else {
                // A page with text content (or no/multiple images): not an
                // image-only book.
                return nil
            }
            hrefs.append(resolveHref(base: link.href, relative: src))
        }
        guard !hrefs.isEmpty else { return nil }

        let rtl: Bool?
        switch publication.metadata.readingProgression {
        case .rtl: rtl = true
        case .ltr: rtl = false
        default: rtl = nil
        }

        logger.info("Image-only ePub detected: \(hrefs.count) pages, rtl=\(String(describing: rtl), privacy: .public)")
        return EpubImagePageSource(fileURL: fileURL, imageHrefs: hrefs, prefersRightToLeft: rtl)
    }

    // MARK: - ReaderPageSource

    func image(page: Int) async throws -> UIImage {
        guard page >= 1, page <= imageHrefs.count else {
            throw EpubImageError.pageMissing(page)
        }
        if let cached = cache.object(forKey: NSNumber(value: page)) {
            return cached
        }

        let href = imageHrefs[page - 1]
        let publication = try await openIfNeeded()
        guard
            let url = AnyURL(string: href),
            let resource = publication.get(url)
        else {
            throw EpubImageError.resourceMissing(href)
        }
        let data: Data
        switch await resource.read() {
        case let .success(bytes): data = bytes
        case .failure: throw EpubImageError.resourceMissing(href)
        }
        guard let image = UIImage(data: data) else {
            throw EpubImageError.decodeFailed(href)
        }
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale)
        cache.setObject(image, forKey: NSNumber(value: page), cost: max(cost, 1))
        return image
    }

    func prefetch(pages: [Int]) {
        for page in pages where prefetchTasks[page] == nil {
            guard cache.object(forKey: NSNumber(value: page)) == nil else { continue }
            prefetchTasks[page] = Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.image(page: page)
                } catch {
                    // Display-time loads surface real errors; prefetch is
                    // best-effort by design.
                }
                await self.clearPrefetchTask(page: page)
            }
        }
    }

    func cancelPrefetch(pages: [Int]) {
        for page in pages {
            prefetchTasks[page]?.cancel()
            prefetchTasks[page] = nil
        }
    }

    private func clearPrefetchTask(page: Int) {
        prefetchTasks[page] = nil
    }

    // MARK: - Publication access

    private func openIfNeeded() async throws -> Publication {
        if let publication { return publication }
        guard let opened = await Self.open(fileURL: fileURL) else {
            throw EpubImageError.publicationOpenFailed
        }
        publication = opened
        return opened
    }

    /// Opens the ePub with the same parser stack as the Readium reader.
    private static func open(fileURL rawURL: URL) async -> Publication? {
        guard FileManager.default.fileExists(atPath: rawURL.path) else { return nil }
        guard let fileURL = FileURL(url: rawURL) else { return nil }
        let retriever = AssetRetriever(httpClient: DefaultHTTPClient(configuration: .default))
        guard case let .success(asset) = await retriever.retrieve(url: fileURL) else { return nil }
        let opener = PublicationOpener(parser: EPUBParser())
        guard case let .success(publication) = await opener.open(asset: asset, allowUserInteraction: false) else {
            return nil
        }
        return publication
    }

    // MARK: - XHTML inspection

    /// Returns the single page-image reference in an XHTML document, or `nil`
    /// when the page is not a pure image page.
    ///
    /// Accepts `<img src="…">` and SVG `<image href/xlink:href="…">` (both are
    /// common in Calibre/manga packaging). The page must contain exactly one
    /// image reference and effectively no text.
    static func singleImageSource(in html: String) -> String? {
        let imgPattern = #"<img[^>]*\ssrc\s*=\s*["']([^"']+)["']"#
        let svgPattern = #"<image[^>]*\s(?:xlink:)?href\s*=\s*["']([^"']+)["']"#
        let sources = matches(of: imgPattern, in: html) + matches(of: svgPattern, in: html)
        guard sources.count == 1, let source = sources.first else { return nil }

        // Strip tags; a real image page carries (almost) no text. The
        // threshold tolerates titles/whitespace without letting prose through.
        let text = html
            .replacingOccurrences(of: #"<head\b[\s\S]*?</head>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 40 else { return nil }

        return source
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
    }

    /// Resolves a relative reference (e.g. `../images/00003.jpeg`) against the
    /// page's href (e.g. `text/part0002.html`) into a container-root-relative
    /// path (`images/00003.jpeg`).
    static func resolveHref(base: String, relative: String) -> String {
        if relative.hasPrefix("/") {
            return String(relative.dropFirst())
        }
        var components = base.split(separator: "/").dropLast().map(String.init)
        for part in relative.split(separator: "/").map(String.init) {
            switch part {
            case ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(part)
            }
        }
        return components.joined(separator: "/")
    }
}
