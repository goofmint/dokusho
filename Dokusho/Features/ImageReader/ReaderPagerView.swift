import SwiftUI
import UIKit

/// SwiftUI wrapper around a `UIPageViewController` that drives the image reader.
///
/// Responsibilities:
/// - Builds one ``ReaderPageViewController`` per ``ReaderSpread`` on demand.
/// - Reverses gesture/navigation semantics for right-to-left reading.
/// - Loads page images through the actor ``PageImageLoader`` (1-based pages) and
///   prefetches ahead (+4) / behind (-1), spread-aware.
/// - Routes left/right-third taps to page turns and center taps to the full HUD;
///   a full-width bottom strip toggles only the progress bar, with priority over
///   page turns.
///
/// The parent owns the ``ReaderLayout`` and the current spread index binding; a
/// change in layout (rotation → spread mode) rebuilds the pager while preserving
/// the reading position.
struct ReaderPagerView: UIViewControllerRepresentable {
    let bookID: String
    let layout: ReaderLayout
    let imageLoader: PageImageLoader
    let backgroundColor: UIColor

    /// The current spread index (reading order). Two-way bound to the parent.
    @Binding var currentSpreadIndex: Int

    /// Called when the center third (above the bottom strip) is tapped: toggles
    /// the full HUD (header + progress bar together).
    let onToggleFullHUD: () -> Void
    /// Called when the full-width bottom strip is tapped: toggles only the
    /// progress bar, leaving the header as-is.
    let onToggleProgress: () -> Void
    /// Called when a spread settles, with its reading-order first page and
    /// whether it is the last spread (book completed).
    let onSettle: (_ firstPage: Int, _ isLast: Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: nil
        )
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        pager.view.backgroundColor = backgroundColor
        context.coordinator.pager = pager

        // Tap zones: left/right thirds turn pages, center toggles the full HUD,
        // bottom strip toggles the progress bar.
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.delegate = context.coordinator
        pager.view.addGestureRecognizer(tap)

        context.coordinator.installInitialSpread()
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncIfNeeded()
    }

    /// Cancels in-flight loads and prefetches when the reader is dismissed.
    static func dismantleUIViewController(_ pager: UIPageViewController, coordinator: Coordinator) {
        coordinator.teardown()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject,
        UIPageViewControllerDataSource,
        UIPageViewControllerDelegate,
        UIGestureRecognizerDelegate {
        var parent: ReaderPagerView
        weak var pager: UIPageViewController?

        /// The layout the currently installed controllers were built for, so we
        /// can detect a rebuild (rotation / direction change).
        private var installedLayout: ReaderLayout?
        /// Reading-order index of the spread currently shown.
        private var installedIndex = 0
        /// Live image-load tasks keyed by page number, cancelled on leave.
        private var loadTasks: [Int: Task<Void, Never>] = [:]

        init(parent: ReaderPagerView) {
            self.parent = parent
        }

        // MARK: Installation / sync

        func installInitialSpread() {
            let index = clamp(parent.currentSpreadIndex)
            guard let controller = makeController(at: index) else { return }
            installedLayout = parent.layout
            installedIndex = index
            pager?.setViewControllers(
                [controller],
                direction: .forward,
                animated: false
            )
            reportSettle(index: index)
            updatePrefetch(around: index)
        }

        /// Rebuilds when the layout changed (spread mode / direction), or jumps
        /// when the bound index changed externally (e.g. HUD slider).
        func syncIfNeeded() {
            if installedLayout != parent.layout {
                // Preserve position: map the current reading page into the new layout.
                let currentPage = currentSpread()?.readingOrderFirstPage ?? 1
                let newIndex = parent.layout.spreadIndex(containing: currentPage)
                rebuild(to: newIndex)
                return
            }
            let target = clamp(parent.currentSpreadIndex)
            if target != installedIndex {
                jump(to: target)
            }
        }

        private func rebuild(to index: Int) {
            cancelAllLoads()
            guard let controller = makeController(at: index) else { return }
            installedLayout = parent.layout
            installedIndex = index
            pager?.setViewControllers([controller], direction: .forward, animated: false)
            reportSettle(index: index)
            updatePrefetch(around: index)
        }

        private func jump(to index: Int) {
            guard index != installedIndex else { return }
            guard let controller = makeController(at: index) else { return }
            // Visual direction depends on reading progression.
            let goingForward = index > installedIndex
            let direction = navigationDirection(forward: goingForward)
            installedIndex = index
            pager?.setViewControllers([controller], direction: direction, animated: true)
            reportSettle(index: index)
            updatePrefetch(around: index)
        }

        // MARK: Controller factory + image loading

        private func makeController(at index: Int) -> ReaderPageViewController? {
            let spreads = parent.layout.spreads
            guard spreads.indices.contains(index) else { return nil }
            let controller = ReaderPageViewController(
                spread: spreads[index],
                spreadIndex: index,
                progression: parent.layout.progression,
                backgroundColor: parent.backgroundColor
            )
            controller.onRetry = { [weak self, weak controller] page in
                guard let self, let controller else { return }
                controller.showLoading(for: page)
                self.load(page: page, into: controller)
            }
            // Kick off loads for each page in the spread.
            for page in spreads[index].pages {
                load(page: page, into: controller)
            }
            return controller
        }

        /// Loads a single page image (1-based) into a controller, with error
        /// surfacing. Auto-retry/backoff lives in ``PageImageLoader``; not
        /// duplicated here.
        private func load(page: Int, into controller: ReaderPageViewController) {
            loadTasks[page]?.cancel()
            let loader = parent.imageLoader
            let bookID = parent.bookID
            loadTasks[page] = Task { [weak self, weak controller] in
                do {
                    let image = try await loader.image(bookID: bookID, page: page)
                    if Task.isCancelled { return }
                    await MainActor.run {
                        controller?.setImage(image, for: page)
                    }
                } catch {
                    if Task.isCancelled { return }
                    await MainActor.run {
                        controller?.showError(for: page)
                    }
                }
                await MainActor.run {
                    self?.loadTasks[page] = nil
                }
            }
        }

        // MARK: Prefetch (+4 ahead / -1 behind, spread-aware)

        private func updatePrefetch(around index: Int) {
            let spreads = parent.layout.spreads
            guard !spreads.isEmpty else { return }
            var aheadPages: [Int] = []
            for offset in 1...2 { // up to 2 spreads ahead ≈ up to 4 pages
                let i = index + offset
                if spreads.indices.contains(i) {
                    aheadPages.append(contentsOf: spreads[i].pages)
                }
            }
            var behindPages: [Int] = []
            let behind = index - 1
            if spreads.indices.contains(behind) {
                // Only the nearest page behind (design: -1).
                behindPages = Array(spreads[behind].pages.suffix(1))
            }
            let bookID = parent.bookID
            let loader = parent.imageLoader
            let prefetch = Array((aheadPages.prefix(4)) + behindPages)
            Task { await loader.prefetch(bookID: bookID, pages: prefetch) }
        }

        private func cancelAllLoads() {
            for task in loadTasks.values { task.cancel() }
            loadTasks.removeAll()
        }

        func teardown() {
            cancelAllLoads()
            let bookID = parent.bookID
            let loader = parent.imageLoader
            let allPages = parent.layout.spreads.flatMap(\.pages)
            Task { await loader.cancelPrefetch(bookID: bookID, pages: allPages) }
        }

        // MARK: Data source (reversed for RTL)

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard let current = viewController as? ReaderPageViewController else { return nil }
            // "Before" is the visual-left neighbor. In reading order that is the
            // previous spread for LTR, the next spread for RTL.
            let target = parent.layout.progression.isRightToLeft
                ? current.spreadIndex + 1
                : current.spreadIndex - 1
            return makeController(at: target)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let current = viewController as? ReaderPageViewController else { return nil }
            // "After" is the visual-right neighbor: next spread for LTR, previous
            // spread for RTL.
            let target = parent.layout.progression.isRightToLeft
                ? current.spreadIndex - 1
                : current.spreadIndex + 1
            return makeController(at: target)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            guard completed,
                  let current = pager?.viewControllers?.first as? ReaderPageViewController
            else { return }
            installedIndex = current.spreadIndex
            if parent.currentSpreadIndex != current.spreadIndex {
                parent.currentSpreadIndex = current.spreadIndex
            }
            reportSettle(index: current.spreadIndex)
            updatePrefetch(around: current.spreadIndex)
        }

        // MARK: Tap zones

        /// Fraction of the view height, measured from the bottom, reserved as a
        /// full-width progress-toggle strip. Taps here never turn a page, so
        /// tapping near the footer reveals the progress bar instead of flipping a
        /// page or touching the header.
        private static let bottomStripFraction: CGFloat = 0.2

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = pager?.view else { return }
            let location = gesture.location(in: view)

            // Bottom strip (full width) toggles only the progress bar, taking
            // priority over the left/right page-turn zones.
            let bottomStripTop = view.bounds.height * (1 - Self.bottomStripFraction)
            if location.y >= bottomStripTop {
                parent.onToggleProgress()
                return
            }

            let third = view.bounds.width / 3
            if location.x < third {
                turnPage(towardVisualLeft: true)
            } else if location.x > third * 2 {
                turnPage(towardVisualLeft: false)
            } else {
                // Center third above the bottom strip: toggle the full HUD.
                parent.onToggleFullHUD()
            }
        }

        /// Turns a page toward the visual left or right edge, translating that to
        /// a reading-order step via the progression.
        private func turnPage(towardVisualLeft: Bool) {
            let rtl = parent.layout.progression.isRightToLeft
            // Visual-left tap = previous in reading order (LTR) / next (RTL).
            let goForwardInReading = rtl ? towardVisualLeft : !towardVisualLeft
            let target = installedIndex + (goForwardInReading ? 1 : -1)
            guard parent.layout.spreads.indices.contains(target) else { return }
            jump(to: target)
        }

        // Let the tap recognizer coexist with the pager's internal swipe.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        // MARK: Helpers

        private func navigationDirection(forward: Bool) -> UIPageViewController.NavigationDirection {
            let rtl = parent.layout.progression.isRightToLeft
            // Reading-forward animates toward the visual left in RTL.
            if forward {
                return rtl ? .reverse : .forward
            } else {
                return rtl ? .forward : .reverse
            }
        }

        private func currentSpread() -> ReaderSpread? {
            let spreads = installedLayout?.spreads ?? parent.layout.spreads
            return spreads.indices.contains(installedIndex) ? spreads[installedIndex] : nil
        }

        private func reportSettle(index: Int) {
            let spreads = parent.layout.spreads
            guard spreads.indices.contains(index) else { return }
            let spread = spreads[index]
            parent.onSettle(spread.readingOrderFirstPage, parent.layout.isLastSpread(index))
        }

        private func clamp(_ index: Int) -> Int {
            let count = parent.layout.spreads.count
            guard count > 0 else { return 0 }
            return min(max(index, 0), count - 1)
        }
    }
}
