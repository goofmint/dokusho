import KomgaKit
import Observation

/// Shared state for presenting an online book reader above the app shell.
@MainActor
@Observable
final class ReaderPresentation {
    var presentedBook: KomgaBook?

    /// True from the moment an online reader is requested until its dismissal
    /// has finished flushing progress.
    private(set) var isReaderTransitionActive = false

    /// Incremented after a dismissed online reader has finished flushing its
    /// progress, allowing the presenting detail view to refresh in order.
    private(set) var completedDismissalSequence = 0

    /// Starts presenting `book` unless a reader presentation or its dismissal
    /// flush is already in progress.
    func present(_ book: KomgaBook) {
        guard !isReaderTransitionActive else { return }
        isReaderTransitionActive = true
        presentedBook = book
    }

    /// Marks the dismissal flush complete and publishes a refresh event.
    func didCompleteDismissal() {
        isReaderTransitionActive = false
        completedDismissalSequence += 1
    }
}
