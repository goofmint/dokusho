import Foundation
import SwiftData

/// A read-progress update that could not be sent to the server (offline queue).
///
/// Flushed by `ReadProgressSyncer` on connectivity restore / app launch
/// (Phase 5). Only the latest pending update per book is retained.
@Model
final class PendingProgress {
    /// Komga book identifier.
    @Attribute(.unique) var bookID: String
    /// Page to report (1-based).
    var page: Int
    var completed: Bool
    var queuedAt: Date

    init(bookID: String, page: Int, completed: Bool, queuedAt: Date = .now) {
        self.bookID = bookID
        self.page = page
        self.completed = completed
        self.queuedAt = queuedAt
    }
}
