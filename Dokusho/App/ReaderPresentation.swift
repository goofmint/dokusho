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

    /// Book to present after the current reader's dismissal flush finishes.
    private var pendingNextBook: KomgaBook?

    /// Starts presenting `book` unless a reader presentation or its dismissal
    /// flush is already in progress.
    func present(_ book: KomgaBook) {
        guard !isReaderTransitionActive else { return }
        isReaderTransitionActive = true
        presentedBook = book
    }

    /// Dismisses the current reader so `book` can be presented after flush.
    ///
    /// `presentedBook` is cleared to tear down `fullScreenCover`. The
    /// transition flag stays set until ``didCompleteDismissal()`` runs, so
    /// another `present` cannot interleave. `MainView` awaits
    /// `flushOutstanding()` before calling ``didCompleteDismissal()``.
    func requestNextVolume(_ book: KomgaBook) {
        pendingNextBook = book
        presentedBook = nil
    }

    /// Marks the dismissal flush complete and publishes a refresh event.
    ///
    /// When a next-volume request is pending, presents that book after the
    /// existing reset so the cover is re-shown only after progress flush.
    func didCompleteDismissal() {
        isReaderTransitionActive = false
        completedDismissalSequence += 1
        if let next = pendingNextBook {
            pendingNextBook = nil
            present(next)
        }
    }
}
