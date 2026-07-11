import Foundation
import SwiftData

/// Provides the app's single shared `ModelContainer`.
///
/// Per design.md §10, the `ModelContainer` is created once and shared across
/// the app. Cross-actor hand-off of models is done via `PersistentIdentifier`,
/// never by passing model instances across concurrency domains.
enum PersistenceController {
    /// All SwiftData model types registered with the container.
    static let schema = Schema([
        ServerConfig.self,
        DownloadedBook.self,
        LocalReadingState.self,
        PendingProgress.self,
    ])

    /// Builds the shared, on-disk `ModelContainer`.
    ///
    /// A failure here means the persistence layer is unusable, so we surface it
    /// as a fatal error rather than silently degrading (no fallback per
    /// CLAUDE.md rules). The call site (`DokushoApp`) constructs this once.
    static func makeContainer() -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("SwiftData ModelContainer の初期化に失敗しました: \(error)")
        }
    }
}
