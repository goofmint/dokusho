import SwiftUI
import KomgaKit
import ReadiumNavigator

/// ダウンロード済みの ePub を Readium で表示するリーダー画面。
///
/// オーケストレータからは `book` / `fileURL` / `onProgress` を渡して構築される。
/// 進捗の報告は `onProgress` のみを通じて行い、他サービスへ直接依存しない。
struct EpubReaderScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var viewModel: EpubReaderViewModel
    /// Header (top bar) visibility. A center tap toggles it together with the
    /// progress bar; a bottom-strip tap never touches it.
    @State private var headerVisible = false
    /// Progress bar (bottom bar) visibility. A bottom-strip tap toggles it
    /// independently; a center tap toggles it together with the header.
    @State private var progressVisible = false
    /// スライダーのドラッグ中の値。ドラッグ中はこの値を優先表示し、離した時に移動する。
    @State private var sliderValue: Double = 0
    /// スライダーをユーザーがドラッグしているか。
    @State private var isDraggingSlider = false

    init(
        book: KomgaBook,
        fileURL: URL,
        initialPage: Int? = nil,
        onProgress: @escaping @MainActor (Int, Bool) -> Void
    ) {
        _viewModel = State(
            wrappedValue: EpubReaderViewModel(
                book: book,
                fileURL: fileURL,
                initialPage: initialPage,
                onProgress: onProgress
            )
        )
    }

    var body: some View {
        ZStack {
            content
        }
        .task {
            await viewModel.load()
            viewModel.setColorScheme(dark: colorScheme == .dark)
        }
        .onChange(of: colorScheme) { _, newValue in
            viewModel.setColorScheme(dark: newValue == .dark)
        }
        .statusBarHidden(!headerVisible)
        // Pushed via `navigationDestination`; hide the nav bar so no empty
        // header area pushes the content down. The HUD's own close button
        // handles dismissal. Matches `ImageReaderScreen`.
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .loading:
            loadingView
        case let .failed(error):
            EpubReaderErrorView(error: error) { dismiss() }
        case let .ready(navigator):
            readerView(navigator: navigator)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("ePub を読み込んでいます…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }

    private func readerView(navigator: EPUBNavigatorViewController) -> some View {
        GeometryReader { proxy in
            ZStack {
                EpubNavigatorView(
                    navigator: navigator,
                    onLocationChange: { locator in
                        viewModel.handleLocationChange(locator)
                    },
                    onError: { error in
                        viewModel.handleNavigatorError(error)
                    }
                )
                .ignoresSafeArea()
                .onTapGesture(coordinateSpace: .local) { location in
                    handleTap(at: location, containerHeight: proxy.size.height)
                }

                hudOverlay
            }
        }
    }

    /// Fraction of the view height, from the bottom, treated as the
    /// progress-toggle strip. Matches the image and PDF readers.
    private static let bottomStripFraction: CGFloat = 0.2

    /// Routes a tap by its vertical position: the bottom strip toggles only the
    /// progress bar; anywhere above toggles the full HUD (header + progress).
    private func handleTap(at location: CGPoint, containerHeight: CGFloat) {
        let inBottomStrip = containerHeight > 0
            && location.y >= containerHeight * (1 - Self.bottomStripFraction)
        if inBottomStrip {
            withAnimation(.easeInOut(duration: 0.2)) {
                progressVisible.toggle()
            }
        } else {
            let anyVisible = headerVisible || progressVisible
            withAnimation(.easeInOut(duration: 0.2)) {
                headerVisible = !anyVisible
                progressVisible = !anyVisible
            }
        }
    }

    // MARK: - HUD

    /// Header and progress bar overlay independently. Only the bars hit-test;
    /// the transparent gap between them passes taps through to the navigator so a
    /// center tap always reaches ``handleTap(at:containerHeight:)``.
    private var hudOverlay: some View {
        VStack(spacing: 0) {
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
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .padding(8)
            }
            .accessibilityLabel("閉じる")

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.bookTitle)
                    .font(.headline)
                    .lineLimit(1)
                if !viewModel.chapterTitle.isEmpty {
                    Text(viewModel.chapterTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            fontSizeControls
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.thinMaterial)
    }

    private var fontSizeControls: some View {
        HStack(spacing: 4) {
            Button {
                adjustFontSize(by: -0.1)
            } label: {
                Image(systemName: "textformat.size.smaller")
                    .padding(6)
            }
            .accessibilityLabel("文字を小さく")

            Button {
                adjustFontSize(by: 0.1)
            } label: {
                Image(systemName: "textformat.size.larger")
                    .padding(6)
            }
            .accessibilityLabel("文字を大きく")
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            HStack {
                Text("進捗")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(viewModel.progressPercentText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            // ドラッグで現在位置を移動できるスライダー。ドラッグ中は sliderValue を
            // 優先表示し、離した時に navigator を移動させる。
            Slider(
                value: sliderBinding,
                in: 0...1,
                onEditingChanged: handleSliderEditingChanged
            )
            .accessibilityLabel("読書位置")
            .accessibilityValue(viewModel.progressPercentText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.thinMaterial)
    }

    /// ドラッグ中は `sliderValue`、それ以外は ViewModel の現在進捗を表示する。
    private var sliderBinding: Binding<Double> {
        Binding(
            get: { isDraggingSlider ? sliderValue : viewModel.totalProgression },
            set: { sliderValue = $0 }
        )
    }

    /// スライダーのドラッグ開始/終了を受けて、終了時に navigator を移動させる。
    private func handleSliderEditingChanged(_ editing: Bool) {
        if editing {
            sliderValue = viewModel.totalProgression
            isDraggingSlider = true
        } else {
            isDraggingSlider = false
            let target = sliderValue
            Task { await viewModel.seek(toProgression: target) }
        }
    }

    private func adjustFontSize(by delta: Double) {
        let next = (viewModel.fontSizeMultiplier + delta)
        viewModel.fontSizeMultiplier = min(max(next, 0.5), 2.5)
    }
}

/// エラー時に表示する日本語の全画面ビュー。空ビューは決して出さない。
private struct EpubReaderErrorView: View {
    let error: EpubReaderError
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text(error.title)
                .font(.title3.bold())
            Text(error.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("閉じる") {
                onClose()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}
