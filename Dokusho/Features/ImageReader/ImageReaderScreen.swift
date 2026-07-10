import SwiftUI
import SwiftData
import KomgaKit

/// The image reader for **PDF** books, streaming or downloaded.
///
/// Page bitmaps come from a ``ReaderPageSource``: un-downloaded books stream
/// Komga-rasterized pages (``StreamingPageSource``), downloaded PDFs are
/// rasterized locally (``LocalPdfPageSource``). Page numbers are **1-based**
/// everywhere (Komga convention).
///
/// Composition:
/// - ``ReaderPagerView`` (UIPageViewController) does the paging, zoom, taps,
///   image loading and prefetch.
/// - A HUD overlays a page slider, page label, reading-direction toggle and
///   close button. The header (top bar) and progress bar (bottom bar) are
///   toggled independently: a center tap shows/hides both, a bottom-strip tap
///   toggles only the progress bar.
///
/// Reading direction is resolved once on appear: a per-book override in
/// ``LocalReadingState`` wins; otherwise the series metadata's direction; else
/// LTR. Resume position is the newer of the server `readProgress.page` and the
/// local state.
struct ImageReaderScreen: View {
    let book: KomgaBook
    /// Where page bitmaps come from (streaming API or local PDF rasterizer).
    let source: any ReaderPageSource
    /// Used only for the series reading-direction lookup. `nil` (offline,
    /// downloaded book) falls back to the user's default direction.
    let client: KomgaClient?
    /// Caller-resolved 1-based resume page (local vs. server progress). When
    /// `nil` the screen resolves the resume position itself from
    /// ``LocalReadingState`` and `book.readProgress` (the streaming behavior).
    var initialPage: Int? = nil
    /// (1-based page, completed) — reported on each settle for progress sync.
    let onProgress: @MainActor (Int, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.modelContext) private var modelContext

    @State private var progression: ReadingProgression = .leftToRight
    @State private var currentSpreadIndex = 0
    /// Header (top bar) visibility. Toggled together with the progress bar by a
    /// center tap; the bottom-strip tap never touches it.
    @State private var headerVisible = false
    /// Progress bar (bottom slider) visibility. Toggled independently by a
    /// bottom-strip tap, and together with the header by a center tap.
    @State private var progressVisible = false
    @State private var didResolveInitialState = false

    /// Persisted background choice; shares its key with the Settings screen.
    @AppStorage(ReaderBackground.storageKey) private var backgroundRaw = ReaderBackground.defaultValue.rawValue

    private var background: ReaderBackground {
        ReaderBackground(rawValue: backgroundRaw) ?? .black
    }

    /// The source's own count (a local `PDFDocument`) is authoritative; the
    /// server-side book metadata is the fallback for streaming.
    private var pageCount: Int {
        if let sourceCount = source.pageCount {
            return max(sourceCount, 1)
        }
        return max(book.media.pagesCount, 1)
    }

    /// Spreads are used in landscape or on regular-width (iPad) layouts.
    private var usesSpread: Bool {
        horizontalSizeClass == .regular || isLandscape
    }

    @State private var isLandscape = false

    private var layout: ReaderLayout {
        ReaderLayout(pageCount: pageCount, usesSpread: usesSpread, progression: progression)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(background.uiColor).ignoresSafeArea()

                if didResolveInitialState {
                    ReaderPagerView(
                        layout: layout,
                        source: source,
                        backgroundColor: background.uiColor,
                        currentSpreadIndex: $currentSpreadIndex,
                        onToggleFullHUD: { toggleFullHUD() },
                        onToggleProgress: { toggleProgress() },
                        onSettle: handleSettle
                    )
                    .ignoresSafeArea()
                }

                hudOverlay
            }
            .onAppear { isLandscape = proxy.size.width > proxy.size.height }
            .onChange(of: proxy.size) { _, newValue in
                isLandscape = newValue.width > newValue.height
            }
        }
        .statusBarHidden(!headerVisible)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task {
            guard !didResolveInitialState else { return }
            await resolveInitialState()
        }
    }

    // MARK: - HUD

    /// Overlays the header and progress bar independently. Only the bars
    /// themselves hit-test; the transparent gap between them passes taps through
    /// to the pager so a center tap always reaches ``ReaderPagerView`` and can
    /// hide the HUD.
    private var hudOverlay: some View {
        VStack {
            if headerVisible {
                topBar
                    .transition(.opacity)
            }
            Spacer()
                .allowsHitTesting(false)
            if progressVisible {
                bottomBar
                    .transition(.opacity)
            }
        }
        .padding()
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
            Spacer()
            Text(bookTitle)
                .font(.headline)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
            Spacer()
            Button {
                toggleDirection()
            } label: {
                Image(systemName: progression.isRightToLeft ? "arrow.left" : "arrow.right")
                    .font(.title3.weight(.semibold))
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel(progression.label)
        }
    }

    private var bottomBar: some View {
        // Direction-aware slider with a compact page label; no standalone footer.
        HStack(spacing: 12) {
            pageSlider
            Text("\(currentPageLabel) / \(pageCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var pageSlider: some View {
        let spreadCount = max(layout.spreads.count, 1)
        // Slider value tracks the *visual* position; reverse mapping for RTL so
        // the thumb moves in the natural reading direction.
        let binding = Binding<Double>(
            get: {
                let idx = Double(currentSpreadIndex)
                return progression.isRightToLeft ? Double(spreadCount - 1) - idx : idx
            },
            set: { newValue in
                let rounded = Int(newValue.rounded())
                let idx = progression.isRightToLeft ? (spreadCount - 1) - rounded : rounded
                currentSpreadIndex = min(max(idx, 0), spreadCount - 1)
            }
        )
        return Slider(
            value: binding,
            in: 0...Double(max(spreadCount - 1, 1)),
            step: 1
        )
        .disabled(spreadCount <= 1)
    }

    private var currentPageLabel: Int {
        guard layout.spreads.indices.contains(currentSpreadIndex) else { return 1 }
        return layout.spreads[currentSpreadIndex].readingOrderFirstPage
    }

    private var bookTitle: String {
        book.metadata.title.isEmpty ? book.name : book.metadata.title
    }

    // MARK: - HUD toggling

    /// Center tap: if either bar is visible, hide both; otherwise show both.
    private func toggleFullHUD() {
        let anyVisible = headerVisible || progressVisible
        withAnimation(.easeInOut(duration: 0.2)) {
            headerVisible = !anyVisible
            progressVisible = !anyVisible
        }
    }

    /// Bottom-strip tap: toggle only the progress bar; leave the header as-is.
    private func toggleProgress() {
        withAnimation(.easeInOut(duration: 0.2)) {
            progressVisible.toggle()
        }
    }

    // MARK: - Settle / progress

    private func handleSettle(firstPage: Int, isLast: Bool) {
        onProgress(firstPage, isLast)
    }

    // MARK: - Direction

    private func toggleDirection() {
        progression = progression.toggled
        persistDirectionOverride(progression)
    }

    private func persistDirectionOverride(_ progression: ReadingProgression) {
        let bookID = book.id
        let descriptor = FetchDescriptor<LocalReadingState>(
            predicate: #Predicate { $0.bookID == bookID }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.readingDirectionOverride = progression.rawValue
            existing.updatedAt = .now
        } else {
            modelContext.insert(
                LocalReadingState(
                    bookID: bookID,
                    lastPage: currentPageLabel,
                    completed: false,
                    readingDirectionOverride: progression.rawValue
                )
            )
        }
        try? modelContext.save()
    }

    // MARK: - Initial resolution (direction + resume position)

    private func resolveInitialState() async {
        let localState = fetchLocalState()

        // Direction: per-book override wins, else series metadata, else the
        // user's default-direction setting (which itself defaults to LTR).
        if let override = ReadingProgression.fromOverride(localState?.readingDirectionOverride) {
            progression = override
        } else if let seriesDirection = await fetchSeriesDirection() {
            progression = ReadingProgression.from(seriesDirection: seriesDirection)
        } else {
            progression = ReadingProgression(rawValue: ReadingDirectionDefault.current().rawValue) ?? .leftToRight
        }

        // Resume position: newer of server progress vs local state.
        let resumePage = resolveResumePage(localState: localState)
        currentSpreadIndex = layout.spreadIndex(containing: resumePage)

        didResolveInitialState = true
    }

    private func resolveResumePage(localState: LocalReadingState?) -> Int {
        // A caller-resolved page (downloaded books, where `book.readProgress`
        // is a stale snapshot) wins outright.
        if let initialPage {
            return min(max(initialPage, 1), pageCount)
        }
        let serverPage = book.readProgress?.page
        let localPage = localState?.lastPage
        let localNewer: Bool
        if let localUpdated = localState?.updatedAt, let serverDate = book.readProgress?.readDate {
            localNewer = localUpdated > serverDate
        } else {
            localNewer = localState != nil && book.readProgress == nil
        }
        let page: Int
        if localNewer, let localPage {
            page = localPage
        } else if let serverPage {
            page = serverPage
        } else {
            page = localPage ?? 1
        }
        return min(max(page, 1), pageCount)
    }

    private func fetchLocalState() -> LocalReadingState? {
        let bookID = book.id
        let descriptor = FetchDescriptor<LocalReadingState>(
            predicate: #Predicate { $0.bookID == bookID }
        )
        return try? modelContext.fetch(descriptor).first
    }

    /// Fetches the series' reading direction. Returns `nil` when offline or the
    /// series cannot be fetched (the caller then falls back to the default).
    private func fetchSeriesDirection() async -> KomgaReadingDirection? {
        guard let client else { return nil }
        do {
            return try await client.series(id: book.seriesId).metadata.readingDirection
        } catch {
            return nil
        }
    }
}
