import SwiftUI
import PDFKit
import KomgaKit

/// The reader body shown once the ``PDFDocument`` has opened successfully.
///
/// Owns the HUD (close button, page indicator, slider, reading-direction toggle)
/// and drives the underlying `PDFView` through a shared ``PdfReaderState``.
struct PdfReaderView: View {
    private let book: KomgaBook
    private let document: PDFDocument
    private let onProgress: @MainActor (Int, Bool) -> Void
    private let onClose: () -> Void

    /// 1-based page the user last read on the server, if any.
    private let initialPage: Int

    @State private var state: PdfReaderState
    @State private var isHUDVisible = true

    /// Persisted reader background choice; shares its key with the Settings
    /// screen and the streaming image reader.
    @AppStorage(ReaderBackground.storageKey) private var backgroundRaw = ReaderBackground.defaultValue.rawValue

    private var background: ReaderBackground {
        ReaderBackground(rawValue: backgroundRaw) ?? ReaderBackground.defaultValue
    }

    init(
        book: KomgaBook,
        document: PDFDocument,
        onProgress: @escaping @MainActor (Int, Bool) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.book = book
        self.document = document
        self.onProgress = onProgress
        self.onClose = onClose

        // Resume position: readProgress.page is 1-based. Clamp to the document's
        // valid range so a stale/out-of-range value can never crash the reader.
        let pageCount = document.pageCount
        let resume = book.readProgress?.page ?? 1
        let clamped = min(max(resume, 1), max(pageCount, 1))
        self.initialPage = clamped

        _state = State(initialValue: PdfReaderState(pageCount: pageCount))
    }

    var body: some View {
        ZStack {
            state.backgroundColor.ignoresSafeArea()

            PdfKitView(
                document: document,
                initialPageIndex: initialPage - 1,
                displaysRTL: state.displaysRTL,
                requestedPage: $state.requestedPage,
                onPageChanged: handlePageChanged
            )
            .ignoresSafeArea()
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isHUDVisible.toggle()
                }
            }

            if isHUDVisible {
                hudOverlay
                    .transition(.opacity)
            }
        }
        .statusBarHidden(!isHUDVisible)
        .onAppear {
            // Apply the persisted reader background, then emit the resume
            // position so the caller's progress state reflects where the reader
            // actually opened.
            state.backgroundColor = Color(background.uiColor)
            reportProgress(page: initialPage)
        }
        .onChange(of: backgroundRaw) { _, _ in
            state.backgroundColor = Color(background.uiColor)
        }
    }

    // MARK: - HUD

    private var hudOverlay: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            bottomBar
        }
    }

    private var topBar: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("閉じる")

            Spacer()

            Text(book.metadata.title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button {
                state.toggleReadingDirection()
            } label: {
                Image(systemName: state.displaysRTL
                      ? "arrow.left.to.line"
                      : "arrow.right.to.line")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(state.displaysRTL ? "右綴じ(右から左)" : "左綴じ(左から右)")
        }
        .padding(.horizontal, 8)
        .background(.regularMaterial)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            Text("\(state.currentPage) / \(state.pageCount)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)

            if state.pageCount > 1 {
                Slider(
                    value: sliderBinding,
                    in: 1...Double(state.pageCount),
                    step: 1
                )
                .accessibilityLabel("ページ")
                .accessibilityValue("\(state.currentPage) / \(state.pageCount)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    /// Slider drives the PDFView via ``PdfReaderState/requestedPage``; PDFView
    /// notifications keep ``currentPage`` authoritative for the label.
    private var sliderBinding: Binding<Double> {
        Binding(
            get: { Double(state.currentPage) },
            set: { newValue in
                state.requestedPage = Int(newValue.rounded())
            }
        )
    }

    // MARK: - Progress

    private func handlePageChanged(_ oneBasedPage: Int) {
        state.currentPage = oneBasedPage
        reportProgress(page: oneBasedPage)
    }

    private func reportProgress(page: Int) {
        let completed = page >= state.pageCount
        onProgress(page, completed)
    }
}
