import KomgaKit
import Observation

/// Shared state for presenting an online book reader above the app shell.
@MainActor
@Observable
final class ReaderPresentation {
    var presentedBook: KomgaBook?
}
