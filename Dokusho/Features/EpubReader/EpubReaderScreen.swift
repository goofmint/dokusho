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
    /// HUD is hidden while reading; a tap shows it.
    @State private var isHUDVisible = false

    init(
        book: KomgaBook,
        fileURL: URL,
        onProgress: @escaping @MainActor (Int, Bool) -> Void
    ) {
        _viewModel = State(
            wrappedValue: EpubReaderViewModel(
                book: book,
                fileURL: fileURL,
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
        .statusBarHidden(!isHUDVisible)
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
            // スライダーは現在位置の可視化用（読み取り主体）。
            ProgressView(value: viewModel.totalProgression, total: 1.0)
                .progressViewStyle(.linear)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.thinMaterial)
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
