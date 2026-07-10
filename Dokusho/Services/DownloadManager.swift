import Foundation
import Observation
import SwiftData
import os
import KomgaKit

/// Lifecycle state of a single book download.
///
/// Mirrors design.md §2.2. `failed` carries the underlying error so the UI can
/// surface a reason without the manager swallowing it.
enum DownloadState: Sendable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case failed(Error)
}

extension DownloadState {
    /// Stable raw string persisted to `DownloadedBook.state`.
    ///
    /// `downloading` and `failed` are transient: they are not meaningfully
    /// resumable purely from a persisted string (an interrupted download is
    /// reconciled against the filesystem on launch), so both persist as
    /// `"pending"`. Only `downloaded` / `notDownloaded` are durable.
    var persistedRawValue: String {
        switch self {
        case .notDownloaded: return "notDownloaded"
        case .downloading: return "pending"
        case .downloaded: return "downloaded"
        case .failed: return "pending"
        }
    }
}

/// Errors originating from ``DownloadManager`` itself (as opposed to transport
/// or Komga API errors).
enum DownloadError: LocalizedError {
    /// The book's `mediaProfile` is neither `EPUB` nor `PDF`, so it cannot be
    /// downloaded for offline reading. Never silently skipped — always thrown.
    case unsupportedMediaProfile(String)
    /// A download task ended without producing a usable local file.
    case missingDownloadedFile

    var errorDescription: String? {
        switch self {
        case let .unsupportedMediaProfile(profile):
            return "このフォーマット（\(profile)）はダウンロードに対応していません。"
        case .missingDownloadedFile:
            return "ダウンロードしたファイルが見つかりませんでした。"
        }
    }
}

/// Manages background downloads of ePub/PDF book files and their local storage.
///
/// Uses a background `URLSession` so downloads continue while the app is
/// suspended; completion is flushed via ``AppDelegate`` (see
/// `handleBackgroundEvents(completionHandler:)`). All mutable state is confined
/// to the main actor; the background session's delegate callbacks hop here via
/// the nested `SessionDelegate`.
@MainActor
@Observable
final class DownloadManager {
    /// Background session identifier. Must be stable across launches so the
    /// system can reattach in-flight downloads.
    static let sessionIdentifier = "jp.moongift.dokusho.downloads"

    /// In-memory snapshot of each known book's state, keyed by bookID. This is
    /// the source of truth `state(for:)` reads; it is seeded from SwiftData on
    /// init and kept in sync with delegate callbacks.
    private var states: [String: DownloadState] = [:]

    /// Active download tasks keyed by bookID (for cancellation).
    @ObservationIgnored private var activeTasks: [String: URLSessionDownloadTask] = [:]

    /// Reverse map from a task's identifier to its bookID, so delegate
    /// callbacks (which only carry the task) can resolve the book.
    @ObservationIgnored private var taskToBook: [Int: String] = [:]

    /// Resume data retained from a failed/cancelled download, keyed by bookID.
    @ObservationIgnored private var resumeData: [String: Data] = [:]

    /// Completion handler stored by ``AppDelegate`` when the system wakes the
    /// app for background session events. Invoked once the session drains.
    @ObservationIgnored private var backgroundCompletionHandler: (() -> Void)?

    @ObservationIgnored private let client: KomgaClient
    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let logger = Logger(subsystem: "jp.moongift.dokusho", category: "DownloadManager")

    /// The background session. Built in `init` (not `lazy`, which `@Observable`
    /// disallows) so it reattaches to in-flight downloads immediately. Marked
    /// `@ObservationIgnored` because it is not UI state.
    @ObservationIgnored private var session: URLSession!

    /// Creates the manager and reconciles persisted records against the disk.
    ///
    /// - Parameters:
    ///   - client: Komga client, used to build authenticated download requests.
    ///   - modelContext: The shared SwiftData context (main-actor bound).
    init(client: KomgaClient, modelContext: ModelContext) {
        self.client = client
        self.modelContext = modelContext
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        self.session = URLSession(
            configuration: configuration,
            delegate: SessionDelegate(manager: self),
            delegateQueue: nil
        )
        reconcile()
        reattachRunningTasks()
    }

    // MARK: - Public API

    /// Current state for a book. Unknown books are `.notDownloaded`.
    func state(for bookID: String) -> DownloadState {
        states[bookID] ?? .notDownloaded
    }

    /// Starts (or resumes) a download for the given book.
    ///
    /// - Throws: ``DownloadError/unsupportedMediaProfile`` when the book is not
    ///   ePub/PDF, or a KomgaKit error when the request cannot be built.
    func download(book: KomgaBook) throws {
        let profile = normalizedProfile(book.media.mediaProfile)
        guard profile == "EPUB" || profile == "PDF" else {
            throw DownloadError.unsupportedMediaProfile(book.media.mediaProfile)
        }

        // Already downloaded or in flight: no-op.
        switch state(for: book.id) {
        case .downloaded:
            return
        case .downloading:
            return
        case .notDownloaded, .failed:
            break
        }

        let request = try client.fileDownloadRequest(bookID: book.id)
        upsertRecord(for: book, profile: profile, state: .downloading(progress: 0))
        // Persist the full book metadata alongside the file so the book can be
        // opened offline (airplane mode) without re-fetching from the server.
        persistBookMetadata(book)

        let task: URLSessionDownloadTask
        if let data = resumeData.removeValue(forKey: book.id) {
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: request)
        }
        // Tag the task so delegate callbacks can resolve the book id.
        task.taskDescription = book.id
        activeTasks[book.id] = task
        taskToBook[task.taskIdentifier] = book.id
        states[book.id] = .downloading(progress: 0)
        task.resume()
        logger.info("Started download for book \(book.id, privacy: .public) profile=\(profile, privacy: .public)")
    }

    /// Cancels an in-flight download, retaining resume data when available.
    func cancel(bookID: String) {
        guard let task = activeTasks[bookID] else { return }
        task.cancel(byProducingResumeData: { [weak self] data in
            guard let data else { return }
            Task { @MainActor in
                self?.resumeData[bookID] = data
            }
        })
        clearActive(bookID: bookID)
        states[bookID] = .notDownloaded
        updatePersistedState(bookID: bookID, to: .notDownloaded)
        logger.info("Cancelled download for book \(bookID, privacy: .public)")
    }

    /// Deletes a downloaded book: removes files on disk and its record.
    ///
    /// - Throws: A filesystem error if the on-disk directory cannot be removed.
    func delete(bookID: String) throws {
        cancel(bookID: bookID)
        resumeData[bookID] = nil
        let directory = bookDirectory(for: bookID)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        states[bookID] = .notDownloaded
        if let record = record(for: bookID) {
            modelContext.delete(record)
            saveContext()
        }
        logger.info("Deleted download for book \(bookID, privacy: .public)")
    }

    /// The on-disk file URL for a fully downloaded book, or `nil` if absent.
    func localURL(for bookID: String) -> URL? {
        guard case .downloaded = state(for: bookID) else { return nil }
        guard let record = record(for: bookID) else { return nil }
        let url = fileURL(for: bookID, profile: record.mediaProfile)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The decoded ``KomgaBook`` persisted alongside a downloaded book, or `nil`
    /// when the metadata sidecar (`book.json`) is missing or cannot be decoded.
    ///
    /// Enables opening the reader offline without a server round-trip. Returns
    /// `nil` explicitly (no fallback) so callers can surface a clear message.
    func localBook(for bookID: String) -> KomgaBook? {
        let url = bookMetadataURL(for: bookID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.metadataDecoder.decode(KomgaBook.self, from: data)
    }

    /// Total size in bytes of all fully downloaded books.
    func totalDownloadedSize() -> Int {
        downloadedRecords().reduce(0) { $0 + $1.totalBytes }
    }

    /// All persisted download records, for the management screen.
    func allRecords() -> [DownloadedBook] {
        (try? modelContext.fetch(FetchDescriptor<DownloadedBook>())) ?? []
    }

    // MARK: - AppDelegate hook

    /// Stores the system-provided completion handler for background events.
    ///
    /// Called from ``AppDelegate`` when the app is woken for background session
    /// events. The handler is invoked once the session finishes dispatching its
    /// queued delegate messages (see `SessionDelegate.urlSessionDidFinishEvents`).
    /// The session is already materialized in `init`, so it has reattached to
    /// the shared background transfer daemon by the time this is called.
    func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Self.sessionIdentifier else {
            // Not our session; call the handler immediately so the system is
            // not left waiting.
            completionHandler()
            return
        }
        backgroundCompletionHandler = completionHandler
    }

    // MARK: - Delegate entry points (main-actor hops from SessionDelegate)

    fileprivate func didWriteData(taskIdentifier: Int, totalWritten: Int64, totalExpected: Int64) {
        guard let bookID = taskToBook[taskIdentifier] else { return }
        guard totalExpected > 0 else { return }
        let progress = Double(totalWritten) / Double(totalExpected)
        states[bookID] = .downloading(progress: progress)
    }

    fileprivate func didFinishDownloading(
        taskIdentifier: Int,
        bookIDFromTask: String?,
        location: URL
    ) {
        guard let bookID = taskToBook[taskIdentifier] ?? bookIDFromTask else {
            logger.error("Finished download for unknown task \(taskIdentifier)")
            return
        }
        guard let record = record(for: bookID) else {
            logger.error("Finished download for book \(bookID, privacy: .public) with no record")
            return
        }
        do {
            let destination = try moveDownloadedFile(from: location, bookID: bookID, profile: record.mediaProfile)
            let size = fileSize(at: destination)
            record.state = DownloadState.downloaded.persistedRawValue
            record.totalBytes = size
            record.downloadedAt = .now
            saveContext()
            states[bookID] = .downloaded
            logger.info("Completed download for book \(bookID, privacy: .public) bytes=\(size)")
        } catch {
            states[bookID] = .failed(error)
            updatePersistedState(bookID: bookID, to: .failed(error))
            logger.error("Failed to persist download for book \(bookID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    fileprivate func didComplete(taskIdentifier: Int, bookIDFromTask: String?, error: Error?) {
        let bookID = taskToBook[taskIdentifier] ?? bookIDFromTask
        defer {
            if let bookID { clearActive(bookID: bookID) }
        }
        guard let bookID else { return }

        guard let error else {
            // Success path already handled in didFinishDownloading.
            return
        }

        // Cancellation is user-initiated; state was already reset in cancel().
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }
        // Retain resume data if the system provided it.
        if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            resumeData[bookID] = data
        }
        states[bookID] = .failed(error)
        updatePersistedState(bookID: bookID, to: .failed(error))
        logger.error("Download failed for book \(bookID, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }

    fileprivate func didFinishBackgroundEvents() {
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        handler?()
    }

    // MARK: - Reconciliation

    /// Reconciles persisted records with the filesystem on launch.
    ///
    /// - A `downloaded` record whose file is missing is reset to
    ///   `notDownloaded` (the user can re-download).
    /// - A `pending`/incomplete record whose file is absent is reset too.
    /// - Orphan files/directories with no matching record are removed.
    private func reconcile() {
        let records = allRecords()
        var knownIDs: Set<String> = []

        for record in records {
            knownIDs.insert(record.bookID)
            let fileURL = fileURL(for: record.bookID, profile: record.mediaProfile)
            let exists = FileManager.default.fileExists(atPath: fileURL.path)
            if record.state == DownloadState.downloaded.persistedRawValue && exists {
                states[record.bookID] = .downloaded
                // Refresh size in case it drifted.
                record.totalBytes = fileSize(at: fileURL)
            } else {
                // Missing file or interrupted download: reset to a clean state
                // and remove any partial directory.
                let directory = bookDirectory(for: record.bookID)
                if FileManager.default.fileExists(atPath: directory.path) {
                    try? FileManager.default.removeItem(at: directory)
                }
                record.state = DownloadState.notDownloaded.persistedRawValue
                record.totalBytes = 0
                record.downloadedAt = nil
                states[record.bookID] = .notDownloaded
            }
        }
        saveContext()

        removeOrphanDirectories(known: knownIDs)
    }

    /// Removes directories under Downloads/ that have no matching record.
    private func removeOrphanDirectories(known: Set<String>) {
        let root = downloadsRoot()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries where !known.contains(entry.lastPathComponent) {
            try? FileManager.default.removeItem(at: entry)
            logger.info("Removed orphan download directory \(entry.lastPathComponent, privacy: .public)")
        }
    }

    /// Reattaches any tasks still running in the background session after a
    /// cold launch, so progress/completion callbacks resume routing correctly.
    private func reattachRunningTasks() {
        session.getAllTasks { [weak self] tasks in
            Task { @MainActor in
                guard let self else { return }
                for task in tasks {
                    guard let downloadTask = task as? URLSessionDownloadTask,
                          let bookID = task.taskDescription else { continue }
                    self.activeTasks[bookID] = downloadTask
                    self.taskToBook[task.taskIdentifier] = bookID
                    if case .downloaded = self.state(for: bookID) {} else {
                        self.states[bookID] = .downloading(progress: 0)
                    }
                }
            }
        }
    }

    // MARK: - SwiftData helpers

    private func record(for bookID: String) -> DownloadedBook? {
        let descriptor = FetchDescriptor<DownloadedBook>(
            predicate: #Predicate { $0.bookID == bookID }
        )
        return (try? modelContext.fetch(descriptor))?.first
    }

    private func downloadedRecords() -> [DownloadedBook] {
        let downloaded = DownloadState.downloaded.persistedRawValue
        let descriptor = FetchDescriptor<DownloadedBook>(
            predicate: #Predicate { $0.state == downloaded }
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func upsertRecord(for book: KomgaBook, profile: String, state: DownloadState) {
        if let existing = record(for: book.id) {
            existing.title = book.metadata.title
            existing.seriesTitle = book.seriesTitle
            existing.mediaProfile = profile
            existing.state = state.persistedRawValue
        } else {
            let record = DownloadedBook(
                bookID: book.id,
                title: book.metadata.title,
                seriesTitle: book.seriesTitle,
                mediaProfile: profile,
                state: state.persistedRawValue,
                totalBytes: 0,
                downloadedAt: nil
            )
            modelContext.insert(record)
        }
        saveContext()
    }

    private func updatePersistedState(bookID: String, to state: DownloadState) {
        guard let record = record(for: bookID) else { return }
        record.state = state.persistedRawValue
        if case .notDownloaded = state {
            record.totalBytes = 0
            record.downloadedAt = nil
        }
        saveContext()
    }

    private func saveContext() {
        do {
            try modelContext.save()
        } catch {
            logger.error("SwiftData save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Bookkeeping

    private func clearActive(bookID: String) {
        if let task = activeTasks.removeValue(forKey: bookID) {
            taskToBook[task.taskIdentifier] = nil
        }
    }

    private func normalizedProfile(_ raw: String) -> String {
        raw.uppercased()
    }

    // MARK: - Filesystem

    /// `Application Support/Downloads/`.
    private func downloadsRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = base.appendingPathComponent("Downloads", isDirectory: true)
        ensureDirectory(root, excludeFromBackup: true)
        return root
    }

    /// `Application Support/Downloads/{bookID}/`.
    private func bookDirectory(for bookID: String) -> URL {
        let directory = downloadsRoot().appendingPathComponent(bookID, isDirectory: true)
        return directory
    }

    /// Full destination file URL, e.g. `.../{bookID}/book.epub`.
    private func fileURL(for bookID: String, profile: String) -> URL {
        let ext = profile.uppercased() == "PDF" ? "pdf" : "epub"
        return bookDirectory(for: bookID).appendingPathComponent("book.\(ext)", isDirectory: false)
    }

    /// The metadata sidecar URL, e.g. `.../{bookID}/book.json`. Removed together
    /// with the book directory on delete and reconciliation.
    private func bookMetadataURL(for bookID: String) -> URL {
        bookDirectory(for: bookID).appendingPathComponent("book.json", isDirectory: false)
    }

    /// Writes the book's full metadata to `book.json` for offline opening.
    private func persistBookMetadata(_ book: KomgaBook) {
        let directory = bookDirectory(for: book.id)
        ensureDirectory(directory, excludeFromBackup: true)
        let url = bookMetadataURL(for: book.id)
        do {
            let data = try Self.metadataEncoder.encode(book)
            try data.write(to: url, options: .atomic)
            try excludeFromBackup(url)
        } catch {
            logger.error("Failed to persist book metadata for \(book.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Encoder/decoder pair for the `book.json` sidecar. Uses matching `.iso8601`
    /// date strategies so a persisted book round-trips exactly (see the KomgaKit
    /// `encodeDecodeBookRoundTrip` test).
    private static let metadataEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let metadataDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Moves a completed temporary download into its final location.
    private func moveDownloadedFile(from tempURL: URL, bookID: String, profile: String) throws -> URL {
        let directory = bookDirectory(for: bookID)
        ensureDirectory(directory, excludeFromBackup: true)
        let destination = fileURL(for: bookID, profile: profile)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
        try excludeFromBackup(destination)
        return destination
    }

    private func ensureDirectory(_ url: URL, excludeFromBackup: Bool) {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        if excludeFromBackup {
            try? self.excludeFromBackup(url)
        }
    }

    private func excludeFromBackup(_ url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }

    private func fileSize(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? Int) ?? 0
    }
}

// MARK: - Background session delegate

/// Bridges the background `URLSession`'s delegate callbacks (delivered off the
/// main actor on the session's delegate queue) to the main-actor
/// ``DownloadManager``.
///
/// Holds a weak reference to avoid a retain cycle (the manager owns the session,
/// which retains this delegate). Each callback hops to the main actor.
///
/// `nonisolated(unsafe)` on the weak reference: it is only ever read to dispatch
/// a main-actor `Task`, so the actual `DownloadManager` state is always touched
/// on the main actor. The reference itself is set once at init.
private final class SessionDelegate: NSObject, URLSessionDownloadDelegate {
    nonisolated(unsafe) weak var manager: DownloadManager?

    init(manager: DownloadManager) {
        self.manager = manager
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let identifier = downloadTask.taskIdentifier
        Task { @MainActor [weak manager] in
            manager?.didWriteData(
                taskIdentifier: identifier,
                totalWritten: totalBytesWritten,
                totalExpected: totalBytesExpectedToWrite
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The temp file at `location` is deleted when this method returns, so we
        // must move it synchronously here rather than after hopping actors.
        let identifier = downloadTask.taskIdentifier
        let bookIDFromTask = downloadTask.taskDescription
        // Move to a stable temp location we control before hopping actors.
        let staged = Self.stage(location)
        Task { @MainActor [weak manager] in
            guard let staged else { return }
            manager?.didFinishDownloading(
                taskIdentifier: identifier,
                bookIDFromTask: bookIDFromTask,
                location: staged
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let identifier = task.taskIdentifier
        let bookIDFromTask = task.taskDescription
        Task { @MainActor [weak manager] in
            manager?.didComplete(
                taskIdentifier: identifier,
                bookIDFromTask: bookIDFromTask,
                error: error
            )
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak manager] in
            manager?.didFinishBackgroundEvents()
        }
    }

    /// Copies the just-finished download to an app-controlled temporary URL so
    /// it survives past the synchronous delegate callback.
    private static func stage(_ location: URL) -> URL? {
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        do {
            try FileManager.default.moveItem(at: location, to: staged)
            return staged
        } catch {
            return nil
        }
    }
}
