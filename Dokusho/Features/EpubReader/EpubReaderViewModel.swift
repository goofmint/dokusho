import Foundation
import Observation
import os
import KomgaKit
import ReadiumNavigator
import ReadiumShared
import ReadiumStreamer

/// ePub リーダー画面の状態と Readium への橋渡しを担う ViewModel。
///
/// ローカル ePub を Readium で開き、`EPUBNavigatorViewController` を保持する。
/// locator の変化を Komga のページ番号へ近似変換し `onProgress` で通知する。
@MainActor
@Observable
final class EpubReaderViewModel {
    /// 読み込みフェーズ。
    enum Phase {
        case loading
        case ready(EPUBNavigatorViewController)
        case failed(EpubReaderError)
    }

    private(set) var phase: Phase = .loading

    /// 現在の全体進捗（0.0〜1.0）。HUD のスライダー・パーセント表示に使う。
    var totalProgression: Double = 0

    /// 現在の章タイトル（取得できた場合）。
    var chapterTitle: String = ""

    /// フォントサイズ倍率（1.0 = 100%）。0.5〜2.5 に制限。
    var fontSizeMultiplier: Double = 1.0 {
        didSet { applyPreferences() }
    }

    private let book: KomgaBook
    private let fileURL: URL
    /// 呼び出し側がローカル/サーバー進捗から解決した resume ページ（1-based）。
    /// `nil` の場合は book の `readProgress` から従来どおり解決する。
    private let initialPage: Int?
    private let onProgress: @MainActor (Int, Bool) -> Void

    /// Komga が解析した総ページ数。progression ↔ page 変換の基準。
    private let pagesCount: Int

    /// 直近に通知した Komga ページ番号。重複通知を避けるために保持。
    private var lastReportedPage: Int?
    private var lastReportedCompleted: Bool = false

    /// 保持中の navigator（preferences 反映のため）。
    private var navigator: EPUBNavigatorViewController?

    /// `load()` 時に取得しておく positions（resume・スライダー操作の両方で使う）。
    /// `[Locator]` は Sendable なので保持しても data race にならない。取得できな
    /// かった場合は空配列。
    private var positions: [Locator] = []

    private let logger = Logger(
        subsystem: "jp.moongift.dokusho",
        category: "EpubReaderViewModel"
    )

    init(
        book: KomgaBook,
        fileURL: URL,
        initialPage: Int? = nil,
        onProgress: @escaping @MainActor (Int, Bool) -> Void
    ) {
        self.book = book
        self.fileURL = fileURL
        self.initialPage = initialPage
        self.onProgress = onProgress
        self.pagesCount = book.media.pagesCount
    }

    var bookTitle: String { book.metadata.title }

    /// 全体進捗をパーセント表記した文字列。
    var progressPercentText: String {
        let pct = Int((totalProgression * 100).rounded())
        return "\(max(0, min(100, pct)))%"
    }

    // MARK: - Loading

    /// ePub を開いて navigator を構築する。失敗時は `phase = .failed` にする。
    func load() async {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            phase = .failed(.fileMissing(path: fileURL.path))
            return
        }

        guard let fileURL = FileURL(url: self.fileURL) else {
            phase = .failed(.assetUnreadable(detail: "file URL の変換に失敗しました"))
            return
        }

        let httpClient = DefaultHTTPClient(configuration: .default)
        let assetRetriever = AssetRetriever(httpClient: httpClient)

        let asset: Asset
        switch await assetRetriever.retrieve(url: fileURL) {
        case let .success(retrieved):
            asset = retrieved
        case let .failure(error):
            phase = .failed(.assetUnreadable(detail: String(describing: error)))
            return
        }

        // PDF 依存を避けるため EPUBParser を直接使う（DefaultPublicationParser は
        // PDFDocumentFactory を要求するため）。
        let opener = PublicationOpener(parser: EPUBParser())

        let publication: Publication
        switch await opener.open(asset: asset, allowUserInteraction: false) {
        case let .success(pub):
            publication = pub
        case let .failure(error):
            phase = .failed(.publicationOpenFailed(detail: String(describing: error)))
            return
        }

        // positions をここで一度だけ取得してキャッシュする。publication は
        // 非 Sendable なので保持せず、Sendable な [Locator] だけを保持する。
        switch await publication.positions() {
        case let .success(loaded):
            positions = loaded
        case let .failure(error):
            logger.error("positions の取得に失敗しました: \(String(describing: error), privacy: .public)")
            positions = []
        }

        let initialLocation = resolveInitialLocation()

        do {
            let navigator = try EPUBNavigatorViewController(
                publication: publication,
                initialLocation: initialLocation,
                config: makeConfiguration()
            )
            self.navigator = navigator
            phase = .ready(navigator)
        } catch {
            phase = .failed(.navigatorInitFailed(detail: String(describing: error)))
        }
    }

    /// resume 位置を決定する。resume ページを全体進捗へ近似変換し、publication の
    /// positions のうち最も近いものを初期 locator とする。
    ///
    /// 呼び出し側から `initialPage`（ローカル/サーバー進捗を解決済み）が渡された
    /// 場合はそれを優先する。渡されない場合は従来どおり book の `readProgress` を
    /// 使い、完了済み・進捗なしなら先頭表示（`nil`）とする。
    private func resolveInitialLocation() -> Locator? {
        let resumePage: Int
        if let initialPage {
            resumePage = initialPage
        } else if let progress = book.readProgress, !progress.completed {
            resumePage = progress.page
        } else {
            return nil
        }

        // (page - 1) / max(pagesCount - 1, 1) で 0.0〜1.0 の全体進捗に近似。
        let denominator = Double(max(pagesCount - 1, 1))
        let target = Double(max(resumePage - 1, 0)) / denominator
        totalProgression = min(max(target, 0), 1)

        // positions から totalProgression が target に最も近い locator を選ぶ。
        // positions を取得できない場合はサイレントに先頭へは倒さず、近似 locator を
        // 作れないため nil（先頭表示）とする。
        return nearestLocator(to: target)
    }

    /// キャッシュ済み positions から、全体進捗が `target` に最も近い locator を返す。
    /// positions が空の場合は `nil`。
    private func nearestLocator(to target: Double) -> Locator? {
        guard !positions.isEmpty else { return nil }
        return positions.min { lhs, rhs in
            let l = abs((lhs.locations.totalProgression ?? 0) - target)
            let r = abs((rhs.locations.totalProgression ?? 0) - target)
            return l < r
        }
    }

    // MARK: - Seeking (slider)

    /// スライダーで指定された全体進捗（0.0〜1.0）へ移動する。
    ///
    /// positions のうち最も近い locator を探して navigator を移動させる。ドラッグ中の
    /// 頻繁な呼び出しに耐えるため positions はキャッシュ済みを使う。失敗はログに残し、
    /// UI の値は要求値に保って不整合を避ける。
    func seek(toProgression progression: Double) async {
        let clamped = min(max(progression, 0), 1)
        totalProgression = clamped

        guard let navigator else { return }
        guard let locator = nearestLocator(to: clamped) else {
            logger.error("スライダー移動に対応する locator が見つかりませんでした (progression=\(clamped, privacy: .public))")
            return
        }
        let moved = await navigator.go(to: locator)
        if !moved {
            logger.error("navigator.go(to:) が失敗しました (progression=\(clamped, privacy: .public))")
        }
    }

    private func makeConfiguration() -> EPUBNavigatorViewController.Configuration {
        EPUBNavigatorViewController.Configuration(preferences: makePreferences())
    }

    private func makePreferences() -> EPUBPreferences {
        EPUBPreferences(
            // リフロー型: 画面が広ければ 2 カラム表示（横向きで画面幅を活かし、
            // 1 カラムのままだと本文が狭く小さく見える問題を解消する）。
            columnCount: .auto,
            fontSize: fontSizeMultiplier,
            // 見開き時は表紙（1 ページ目）を単独表示（画像リーダーと同じ挙動）。
            offsetFirstPage: true,
            // 固定レイアウト型（マンガ等）: 画面が広ければ見開き（2 ページ）表示。
            // 横向きで 1 ページが中央に小さく表示される問題もこれで解消する。
            spread: .auto,
            // テーマはシステムのライト/ダークに追従（View 側から setColorScheme で更新）。
            theme: currentTheme
        )
    }

    private var currentTheme: Theme = .light

    /// システムのカラースキームに合わせてテーマを更新し反映する。
    func setColorScheme(dark: Bool) {
        let theme: Theme = dark ? .dark : .light
        guard theme != currentTheme else { return }
        currentTheme = theme
        applyPreferences()
    }

    private func applyPreferences() {
        navigator?.submitPreferences(makePreferences())
    }

    // MARK: - Progress

    /// navigator の locator 変化を受けて進捗を更新・通知する。
    func handleLocationChange(_ locator: Locator) {
        let progression = locator.locations.totalProgression ?? totalProgression
        totalProgression = min(max(progression, 0), 1)

        if let title = locator.title, !title.isEmpty {
            chapterTitle = title
        }

        let page = komgaPage(for: totalProgression)
        // 全体進捗が終端付近なら完了扱い。
        let completed = totalProgression >= 0.995

        // 同じページ・同じ完了状態を重複通知しない。
        if page == lastReportedPage, completed == lastReportedCompleted {
            return
        }
        lastReportedPage = page
        lastReportedCompleted = completed
        onProgress(page, completed)
    }

    /// navigator が報告した実行時エラーをエラー画面へ反映する。
    func handleNavigatorError(_ error: NavigatorError) {
        phase = .failed(.navigatorInitFailed(detail: String(describing: error)))
    }

    /// 全体進捗（0.0〜1.0）を Komga の 1-based ページ番号へ近似変換する。
    private func komgaPage(for progression: Double) -> Int {
        let span = Double(max(pagesCount - 1, 0))
        let raw = (progression * span).rounded()
        let page = Int(raw) + 1
        return min(max(page, 1), max(pagesCount, 1))
    }
}
