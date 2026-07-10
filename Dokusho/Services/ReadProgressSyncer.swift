import Foundation
import Observation
import Network
import SwiftData
import os
import KomgaKit

/// Synchronizes read progress to the Komga server with debouncing and an
/// offline queue.
///
/// ## Design choice: `@MainActor @Observable class` (not `actor`)
///
/// design.md §2.2 sketches this as an `actor`, but the type's core job is to
/// read and mutate SwiftData (`LocalReadingState`, `PendingProgress`) through the
/// app's shared `ModelContext`, which is **main-actor bound** (see
/// `DownloadManager`, which is also `@MainActor` for the same reason). Modeling
/// this as an actor would force every SwiftData access to hop back to the main
/// actor anyway, and would require threading `PersistentIdentifier`s across the
/// isolation boundary. Confining the whole type to the main actor keeps the
/// SwiftData access straightforward and matches the existing service pattern.
/// The only genuinely concurrent input — `NWPathMonitor` callbacks — hops to the
/// main actor explicitly.
///
/// ## Behavior
///
/// - ``recordProgress(bookID:page:completed:)`` updates ``LocalReadingState``
///   immediately (local truth), then schedules a **2-second debounced** PATCH to
///   the server. Repeated calls for the same book during the window collapse to a
///   single send with the latest value.
/// - On send failure the update is queued to ``PendingProgress`` (only the latest
///   per book is kept) and retried by ``flushPending()``.
/// - ``flushPending()`` is called on launch/connect and whenever `NWPathMonitor`
///   reports the network is satisfied again.
///
/// Page numbers are **1-based** throughout, matching Komga's API.
@MainActor
@Observable
final class ReadProgressSyncer {
    /// Debounce window before a recorded page is PATCHed to the server.
    private static let debounceInterval: Duration = .seconds(2)

    @ObservationIgnored private let client: KomgaClient
    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let logger = Logger(
        subsystem: "jp.moongift.dokusho",
        category: "ReadProgressSyncer"
    )

    /// Pending debounce task per book. A new `recordProgress` cancels and
    /// replaces the book's outstanding task so only the latest value is sent.
    @ObservationIgnored private var debounceTasks: [String: Task<Void, Never>] = [:]

    /// The most recently recorded value per book, read by the debounced send.
    @ObservationIgnored private var latest: [String: (page: Int, completed: Bool)] = [:]

    /// Watches connectivity so queued updates flush on restore.
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private let monitorQueue = DispatchQueue(label: "jp.moongift.dokusho.progress-monitor")
    /// Tracks whether the last observed path was satisfied, so we only flush on
    /// an unsatisfied→satisfied transition (not on every path update).
    @ObservationIgnored private var wasSatisfied = false

    init(client: KomgaClient, modelContext: ModelContext) {
        self.client = client
        self.modelContext = modelContext
        startMonitoring()
    }

    deinit {
        pathMonitor.cancel()
    }

    // MARK: - Public API

    /// Records a page turn: updates local state now, schedules a debounced PATCH.
    ///
    /// - Parameters:
    ///   - bookID: The book id.
    ///   - page: The last page read (1-based).
    ///   - completed: Whether the book is now complete (true on last page).
    func recordProgress(bookID: String, page: Int, completed: Bool) {
        updateLocalState(bookID: bookID, page: page, completed: completed)
        latest[bookID] = (page, completed)

        debounceTasks[bookID]?.cancel()
        debounceTasks[bookID] = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.debounceInterval)
            } catch {
                // Cancelled by a newer recordProgress; the newer task will send.
                return
            }
            guard let self else { return }
            self.debounceTasks[bookID] = nil
            guard let value = self.latest[bookID] else { return }
            await self.send(bookID: bookID, page: value.page, completed: value.completed)
        }
    }

    /// Sends all queued (previously-failed) progress updates to the server.
    ///
    /// Call on launch/connect and on network restore. Successfully sent items are
    /// removed from the queue; items that fail again stay queued.
    func flushPending() async {
        let pending = fetchAllPending()
        for item in pending {
            do {
                try await client.updateReadProgress(
                    bookID: item.bookID,
                    page: item.completed ? nil : item.page,
                    completed: item.completed
                )
                modelContext.delete(item)
                saveContext()
                logger.info("Flushed pending progress for book \(item.bookID, privacy: .public)")
            } catch {
                // Still offline / server unavailable: leave queued for next flush.
                logger.info("Flush deferred for book \(item.bookID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Sending

    /// Attempts a single PATCH; queues on failure.
    private func send(bookID: String, page: Int, completed: Bool) async {
        do {
            try await client.updateReadProgress(
                bookID: bookID,
                page: completed ? nil : page,
                completed: completed
            )
            // On success, drop any stale queued entry for this book.
            removePending(bookID: bookID)
            logger.info("Synced progress for book \(bookID, privacy: .public) page=\(page) completed=\(completed)")
        } catch {
            enqueuePending(bookID: bookID, page: page, completed: completed)
            logger.info("Queued progress for book \(bookID, privacy: .public) (send failed): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Local state

    private func updateLocalState(bookID: String, page: Int, completed: Bool) {
        if let existing = localState(for: bookID) {
            existing.lastPage = page
            existing.completed = completed
            existing.updatedAt = .now
        } else {
            modelContext.insert(
                LocalReadingState(bookID: bookID, lastPage: page, completed: completed)
            )
        }
        saveContext()
    }

    private func localState(for bookID: String) -> LocalReadingState? {
        let descriptor = FetchDescriptor<LocalReadingState>(
            predicate: #Predicate { $0.bookID == bookID }
        )
        return (try? modelContext.fetch(descriptor))?.first
    }

    // MARK: - Pending queue (only latest per book)

    private func enqueuePending(bookID: String, page: Int, completed: Bool) {
        if let existing = pending(for: bookID) {
            existing.page = page
            existing.completed = completed
            existing.queuedAt = .now
        } else {
            modelContext.insert(
                PendingProgress(bookID: bookID, page: page, completed: completed)
            )
        }
        saveContext()
    }

    private func removePending(bookID: String) {
        guard let existing = pending(for: bookID) else { return }
        modelContext.delete(existing)
        saveContext()
    }

    private func pending(for bookID: String) -> PendingProgress? {
        let descriptor = FetchDescriptor<PendingProgress>(
            predicate: #Predicate { $0.bookID == bookID }
        )
        return (try? modelContext.fetch(descriptor))?.first
    }

    private func fetchAllPending() -> [PendingProgress] {
        (try? modelContext.fetch(FetchDescriptor<PendingProgress>())) ?? []
    }

    private func saveContext() {
        do {
            try modelContext.save()
        } catch {
            logger.error("SwiftData save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Connectivity

    private func startMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let restored = satisfied && !self.wasSatisfied
                self.wasSatisfied = satisfied
                if restored {
                    await self.flushPending()
                }
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }
}
