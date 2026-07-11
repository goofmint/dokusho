import Foundation
import SwiftData

/// Persistent record of a downloaded (or downloading) ePub/PDF book.
///
/// The actual file lives under `Application Support/Downloads/{bookID}/`.
/// This record is reconciled against the filesystem on launch (Phase 6).
@Model
final class DownloadedBook {
    /// Komga book identifier.
    @Attribute(.unique) var bookID: String
    var title: String
    var seriesTitle: String
    /// `EPUB` or `PDF` (Komga `media.mediaProfile`).
    var mediaProfile: String
    /// Download lifecycle state (raw string; interpreted by DownloadManager in Phase 6).
    var state: String
    var totalBytes: Int
    var downloadedAt: Date?

    init(
        bookID: String,
        title: String,
        seriesTitle: String,
        mediaProfile: String,
        state: String,
        totalBytes: Int,
        downloadedAt: Date? = nil
    ) {
        self.bookID = bookID
        self.title = title
        self.seriesTitle = seriesTitle
        self.mediaProfile = mediaProfile
        self.state = state
        self.totalBytes = totalBytes
        self.downloadedAt = downloadedAt
    }
}
