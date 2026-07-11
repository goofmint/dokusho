import Foundation
import CryptoKit
import os

/// A small on-disk cache for the browse lists' *first* page of results.
///
/// Backs the stale-while-revalidate behaviour of the library/series/collection/
/// read-list/home screens: on appear the cached first page is shown immediately,
/// then a fresh page 0 is fetched and both the UI and this cache are updated.
///
/// Payloads are stored as JSON files under `Caches/BrowseCache/{sha256(key)}.json`
/// and excluded from backup. This is a *cache*, not a source of truth, so an
/// absent or corrupt entry is treated as a miss (the corrupt file is deleted and
/// the event logged) — the caller falls back to a plain network load. Pagination
/// beyond page 0 is never cached; search results are never cached.
actor BrowseCache {
    /// The process-wide browse cache. Shared so every browse screen reads and
    /// writes the same `Caches/BrowseCache` directory. `AppServices` is not
    /// modified to hold this — the cache is stateless beyond its directory.
    static let shared = BrowseCache()

    private let directory: URL
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "jp.moongift.dokusho", category: "BrowseCache")

    /// Plain encoder/decoder pair; the cached DTO trees contain no `Date` fields,
    /// so no date strategy is required.
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        let base = caches.first ?? fileManager.temporaryDirectory
        directory = base.appendingPathComponent("BrowseCache", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Loads a previously cached value for `key`, or `nil` when the entry is
    /// absent or corrupt. A corrupt file is deleted so it cannot poison future
    /// loads.
    func load<T: Codable>(_ type: T.Type, key: String) -> T? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url) else {
            // Absent (or unreadable) — a normal cache miss, not worth logging.
            return nil
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            logger.error("Corrupt browse cache for \(key, privacy: .public); deleting: \(error.localizedDescription, privacy: .public)")
            try? fileManager.removeItem(at: url)
            return nil
        }
    }

    /// Persists `value` under `key`, replacing any existing entry. A write
    /// failure is logged and ignored — the cache is best-effort.
    func save<T: Codable>(_ value: T, key: String) {
        let url = fileURL(for: key)
        do {
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableURL = url
            try? mutableURL.setResourceValues(resourceValues)
        } catch {
            logger.error("Failed to write browse cache for \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes every cached browse entry (e.g. on disconnect).
    func clear() {
        do {
            try fileManager.removeItem(at: directory)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to clear browse cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Maps a logical key to a filesystem-safe file URL via its SHA-256 hash, so
    /// arbitrary key strings (library IDs, query identities) never produce an
    /// invalid path.
    private func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("json")
    }
}
