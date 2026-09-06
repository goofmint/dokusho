import Foundation
import SwiftData

/// Locally tracked reading state for a book.
///
/// Mirrors the last known page/completion and any user override of the reading
/// direction. Server sync is handled separately by `ReadProgressSyncer` (Phase 5).
@Model
final class LocalReadingState {
    /// Komga book identifier.
    @Attribute(.unique) var bookID: String
    /// Last read page (1-based, matching Komga's page numbering).
    var lastPage: Int
    var completed: Bool
    /// User override of reading direction (`LEFT_TO_RIGHT` / `RIGHT_TO_LEFT`), or nil to use series metadata.
    var readingDirectionOverride: String?
    /// When true, landscape spreads insert a leading blank so real pages pair as (1,2), (3,4)…
    var insertBlankPageAtStart: Bool = false
    var updatedAt: Date

    init(
        bookID: String,
        lastPage: Int,
        completed: Bool,
        readingDirectionOverride: String? = nil,
        insertBlankPageAtStart: Bool = false,
        updatedAt: Date = .now
    ) {
        self.bookID = bookID
        self.lastPage = lastPage
        self.completed = completed
        self.readingDirectionOverride = readingDirectionOverride
        self.insertBlankPageAtStart = insertBlankPageAtStart
        self.updatedAt = updatedAt
    }
}
