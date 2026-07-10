import Foundation
import UIKit
import CryptoKit
import ImageIO
import os
import KomgaKit

/// Loads and caches page images and thumbnails for the browse and reader UIs.
///
/// Two cache layers back every fetch:
///
/// 1. **Memory** — an `NSCache` keyed by a stable string, with the cost of each
///    entry set to its pixel count. Page images and thumbnails use *separate*
///    `NSCache` instances so a flood of thumbnails cannot evict full-resolution
///    reader pages (and vice versa). Both are cleared on a memory warning.
/// 2. **Disk** — files under `Caches/PageCache/` (pages) and
///    `Caches/ThumbnailCache/` (thumbnails), named by the SHA-256 of the logical
///    key. A least-recently-used sweep enforces a configurable byte budget.
///
/// Concurrent requests for the same key share a single in-flight `Task`, so the
/// image is fetched from the network at most once. Unrecoverable failures throw
/// ``PageImageError`` — there are no silent placeholder fallbacks.
actor PageImageLoader {
    /// Failures that cannot be recovered from and are surfaced to callers.
    enum PageImageError: Error, Equatable {
        /// The server returned bytes that could not be decoded as an image,
        /// even after retrying with a JPEG conversion.
        case decodeFailed
        /// The HTTP response was missing or not a success status.
        case badResponse
    }

    // MARK: Configuration

    private let client: KomgaClient
    private let session: URLSession

    /// LRU byte budget for the on-disk page cache. Default 1 GB.
    private let diskLimit: Int
    /// LRU byte budget for the on-disk thumbnail cache. Default 200 MB.
    private let thumbnailDiskLimit: Int

    /// Directory holding cached full-resolution page images.
    private let pageCacheDirectory: URL
    /// Directory holding cached thumbnails.
    private let thumbnailCacheDirectory: URL

    // MARK: Memory caches

    /// Full-resolution page image memory cache. Cost = pixel count.
    private let pageMemoryCache = NSCache<NSString, UIImage>()
    /// Thumbnail memory cache. Cost = pixel count. Separate budget from pages.
    private let thumbnailMemoryCache = NSCache<NSString, UIImage>()

    // MARK: In-flight sharing

    /// Active fetch tasks keyed by cache key, so duplicate requests share one
    /// network round-trip. Covers both pages and thumbnails.
    private var inFlight: [String: Task<UIImage, Error>] = [:]

    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "jp.moongift.dokusho", category: "PageImageLoader")

    /// Approximate cost, in pixels, of a 4-byte RGBA pixel budget.
    /// 150 MB / 4 bytes ≈ 37.5M pixels for page images.
    private static let defaultPageMemoryPixelBudget = 150 * 1024 * 1024 / 4
    /// 200 MB / 4 bytes ≈ 50M pixels for thumbnails.
    private static let defaultThumbnailMemoryPixelBudget = 200 * 1024 * 1024 / 4

    /// Creates a loader.
    ///
    /// - Parameters:
    ///   - client: The Komga client used to build authenticated requests.
    ///   - session: The `URLSession` used for image downloads. Defaults to a
    ///     dedicated ephemeral-free configuration.
    ///   - diskLimit: Page disk-cache byte budget. Defaults to 1 GB.
    ///   - thumbnailDiskLimit: Thumbnail disk-cache byte budget. Defaults to 200 MB.
    init(
        client: KomgaClient,
        session: URLSession = .shared,
        diskLimit: Int = 1024 * 1024 * 1024,
        thumbnailDiskLimit: Int = 200 * 1024 * 1024
    ) {
        self.client = client
        self.session = session
        self.diskLimit = diskLimit
        self.thumbnailDiskLimit = thumbnailDiskLimit

        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        // `Caches` always resolves in a sandboxed app; if it somehow does not,
        // fall back to a temporary directory so the loader still functions.
        let base: URL
        if let first = caches.first {
            base = first
        } else {
            base = fileManager.temporaryDirectory
        }
        pageCacheDirectory = base.appendingPathComponent("PageCache", isDirectory: true)
        thumbnailCacheDirectory = base.appendingPathComponent("ThumbnailCache", isDirectory: true)

        pageMemoryCache.totalCostLimit = Self.defaultPageMemoryPixelBudget
        thumbnailMemoryCache.totalCostLimit = Self.defaultThumbnailMemoryPixelBudget

        try? fileManager.createDirectory(at: pageCacheDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: thumbnailCacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Returns the image for a book page (1-based), fetching and caching it if needed.
    ///
    /// Attempts content negotiation first; if the returned bytes fail to decode,
    /// retries once requesting a JPEG conversion (handles servers that serve WebP).
    func image(bookID: String, page: Int) async throws -> UIImage {
        let key = "page/\(bookID)/\(page)"
        return try await load(
            key: key,
            memoryCache: pageMemoryCache,
            directory: pageCacheDirectory,
            diskLimit: diskLimit,
            downsampleMaxPixel: nil
        ) { @Sendable [client] convert in
            try client.pageImageRequest(bookID: bookID, page: page, convert: convert)
        }
    }

    /// Returns the thumbnail for a resource, fetching and caching it if needed.
    ///
    /// Thumbnails are downsampled to at most 600 px on their long edge to keep
    /// memory and disk footprint small for grid cells.
    func thumbnail(for target: ThumbnailTarget) async throws -> UIImage {
        let key = "thumb/\(target.cacheComponent)"
        return try await load(
            key: key,
            memoryCache: thumbnailMemoryCache,
            directory: thumbnailCacheDirectory,
            diskLimit: thumbnailDiskLimit,
            downsampleMaxPixel: 600
        ) { @Sendable [client] _ in
            try client.thumbnailRequest(for: target)
        }
    }

    /// Warms the cache for the given pages without blocking the caller.
    ///
    /// Requests already in flight or cached are skipped by the normal load path.
    func prefetch(bookID: String, pages: [Int]) {
        for page in pages {
            let key = "page/\(bookID)/\(page)"
            guard inFlight[key] == nil, pageMemoryCache.object(forKey: key as NSString) == nil else {
                continue
            }
            Task { [weak self] in
                _ = try? await self?.image(bookID: bookID, page: page)
            }
        }
    }

    /// Cancels any in-flight prefetch tasks for the given pages.
    func cancelPrefetch(bookID: String, pages: [Int]) {
        for page in pages {
            let key = "page/\(bookID)/\(page)"
            inFlight[key]?.cancel()
            inFlight[key] = nil
        }
    }

    /// Total bytes currently used by both on-disk caches.
    func diskUsage() -> Int {
        directorySize(pageCacheDirectory) + directorySize(thumbnailCacheDirectory)
    }

    /// Clears both memory and disk caches.
    func clearCache() {
        pageMemoryCache.removeAllObjects()
        thumbnailMemoryCache.removeAllObjects()
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        try? fileManager.removeItem(at: pageCacheDirectory)
        try? fileManager.removeItem(at: thumbnailCacheDirectory)
        try? fileManager.createDirectory(at: pageCacheDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: thumbnailCacheDirectory, withIntermediateDirectories: true)
    }

    /// Purges the in-memory caches in response to a memory-pressure signal.
    /// Disk contents are kept; they can be reloaded cheaply.
    func purgeMemory() {
        pageMemoryCache.removeAllObjects()
        thumbnailMemoryCache.removeAllObjects()
    }

    // MARK: - Core load path

    /// Shared load pipeline: memory → disk → network, with in-flight sharing.
    private func load(
        key: String,
        memoryCache: NSCache<NSString, UIImage>,
        directory: URL,
        diskLimit: Int,
        downsampleMaxPixel: Int?,
        makeRequest: @escaping @Sendable (ImageConversion?) throws -> URLRequest
    ) async throws -> UIImage {
        let nsKey = key as NSString

        if let cached = memoryCache.object(forKey: nsKey) {
            return cached
        }

        if let existing = inFlight[key] {
            return try await existing.value
        }

        let fileURL = directory.appendingPathComponent(Self.hash(key))

        let task = Task<UIImage, Error> { [weak self] in
            guard let self else { throw PageImageError.badResponse }

            // Disk hit: decode (and downsample) from the cached bytes.
            if let data = try? Data(contentsOf: fileURL),
               let image = Self.decode(data, downsampleMaxPixel: downsampleMaxPixel) {
                await self.touch(fileURL)
                return image
            }

            // Network fetch (content negotiation first, JPEG retry on decode failure).
            let (data, image) = try await self.fetch(
                makeRequest: makeRequest,
                downsampleMaxPixel: downsampleMaxPixel
            )
            await self.store(data: data, at: fileURL, directory: directory, diskLimit: diskLimit)
            return image
        }

        inFlight[key] = task
        defer { inFlight[key] = nil }

        do {
            let image = try await task.value
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale)
            memoryCache.setObject(image, forKey: nsKey, cost: max(cost, 1))
            return image
        } catch {
            throw error
        }
    }

    /// Performs the network fetch, decoding the bytes. On decode failure, retries
    /// once with an explicit JPEG conversion (`makeRequest` may ignore it, e.g.
    /// for thumbnails, which then simply surfaces the decode error).
    private func fetch(
        makeRequest: @Sendable (ImageConversion?) throws -> URLRequest,
        downsampleMaxPixel: Int?
    ) async throws -> (Data, UIImage) {
        let request = try makeRequest(nil)
        let data = try await performData(request)
        if let image = Self.decode(data, downsampleMaxPixel: downsampleMaxPixel) {
            return (data, image)
        }

        // Retry once forcing JPEG (covers WebP the platform cannot decode).
        let retryRequest = try makeRequest(.jpeg)
        // If the retry request is identical (conversion ignored), don't refetch.
        if retryRequest == request {
            throw PageImageError.decodeFailed
        }
        let retryData = try await performData(retryRequest)
        guard let image = Self.decode(retryData, downsampleMaxPixel: downsampleMaxPixel) else {
            throw PageImageError.decodeFailed
        }
        return (retryData, image)
    }

    /// Executes an image request, validating the HTTP status.
    private func performData(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw KomgaError.network(urlError)
        }
        guard let http = response as? HTTPURLResponse else {
            throw PageImageError.badResponse
        }
        guard (200...299).contains(http.statusCode) else {
            switch http.statusCode {
            case 401: throw KomgaError.invalidAPIKey
            case 403: throw KomgaError.forbidden
            case 404: throw KomgaError.notFound
            default: throw KomgaError.serverError(status: http.statusCode)
            }
        }
        return data
    }

    // MARK: - Disk maintenance

    /// Writes bytes to disk, then evicts least-recently-used files if over budget.
    private func store(data: Data, at fileURL: URL, directory: URL, diskLimit: Int) {
        do {
            try data.write(to: fileURL, options: .atomic)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableURL = fileURL
            try? mutableURL.setResourceValues(resourceValues)
        } catch {
            logger.error("Failed to write cache file: \(error.localizedDescription, privacy: .public)")
            return
        }
        evictIfNeeded(directory: directory, limit: diskLimit)
    }

    /// Updates a file's modification date so LRU treats it as recently used.
    private func touch(_ fileURL: URL) {
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
    }

    /// Enforces the byte budget for a cache directory by removing the oldest
    /// files (by modification date) until under the limit.
    private func evictIfNeeded(directory: URL, limit: Int) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys
        ) else { return }

        var entries: [(url: URL, date: Date, size: Int)] = []
        var total = 0
        for url in files {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let size = values.fileSize else { continue }
            let date = values.contentModificationDate ?? .distantPast
            entries.append((url, date, size))
            total += size
        }

        guard total > limit else { return }
        // Oldest first.
        entries.sort { $0.date < $1.date }
        for entry in entries {
            guard total > limit else { break }
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    /// Sums the byte sizes of all files in a directory.
    private func directorySize(_ directory: URL) -> Int {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(0) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return sum + size
        }
    }

    // MARK: - Decoding helpers

    /// Decodes image bytes, optionally downsampling to a maximum long-edge pixel
    /// size using ImageIO (`kCGImageSourceThumbnailMaxPixelSize`).
    nonisolated private static func decode(_ data: Data, downsampleMaxPixel: Int?) -> UIImage? {
        guard let maxPixel = downsampleMaxPixel else {
            return UIImage(data: data)
        }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return UIImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }

    /// SHA-256 hash of a logical key, used as the on-disk filename.
    nonisolated private static func hash(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private extension ThumbnailTarget {
    /// A stable string component identifying this target for cache keys.
    var cacheComponent: String {
        switch self {
        case let .book(id): return "book/\(id)"
        case let .series(id): return "series/\(id)"
        case let .collection(id): return "collection/\(id)"
        case let .readList(id): return "readlist/\(id)"
        }
    }
}
