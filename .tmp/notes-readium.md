# Readium Swift Toolkit 導入メモ (Task 1.3 依存関係セットアップ)

## 選定バージョン

- **Readium Swift Toolkit `3.10.0`**（記録時点の最新安定版）
- `git ls-remote --tags https://github.com/readium/swift-toolkit.git` で確認。
  安定版の最新は 3.10.0（3.x 系。alpha/beta を除く）。
- pbxproj では **exactVersion 3.10.0** でピン留め（メジャーアップデートで API が
  変わりやすいため、設計書 §10 の方針どおり固定）。

## パッケージ構成（3.10.0）

- swift-tools-version: 5.10
- platforms: iOS 15.0（本アプリの iOS 17 ターゲットは問題なし）
- 提供ライブラリ product:
  - ReadiumShared
  - ReadiumStreamer
  - ReadiumNavigator
  - ReadiumOPDS
  - ReadiumLCP
  - ReadiumAdapterGCDWebServer
  - ReadiumAdapterLCPSQLite

本タスクでは設計書に従い **ReadiumShared / ReadiumStreamer / ReadiumNavigator**
の3プロダクトのみをアプリターゲットにリンク。

## 推移的依存（Xcode が自動解決）

Readium 3.10.0 を追加すると以下が芋づる式に解決される（バージョンは解決結果）:

- ReadiumFuzi (readium fork) 4.0.0
- ReadiumZIPFoundation (readium fork) 3.0.1
- GCDWebServer (readium fork) 4.0.1
- CryptoSwift 1.10.0
- Zip 2.1.2
- DifferenceKit 1.3.0
- SwiftSoup 2.13.6
- SQLite.swift 0.16.0

いずれも SPM で自動取得されるため手動追加は不要。

## リンク確認

- `Dokusho/App/ContentView.swift` に `import ReadiumNavigator` を記述し、
  アプリターゲットへのリンクを担保（Phase 1 のプレースホルダ）。

## セットアップ上の注意点（実装フェーズ向け）

- **GCDWebServer**: `ReadiumStreamer` / ローカル HTTP サーバー経由のリソース配信で
  GCDWebServer を使う構成がある。バックグラウンド動作やローカルサーバーの停止・
  再開はアプリのライフサイクルに合わせて管理する必要がある（Task 6.3 で確認）。
- **EPUBNavigatorViewController**: `Publication` を開くには Streamer で
  ローカル ePub を parse してから Navigator に渡す。初期化フローは Task 6.3 の
  スパイクで確定する。
- **バージョン固定**: 3.x はマイナー間でも API が動くことがあるため exactVersion で
  固定済み。アップグレード時は CHANGELOG を確認してから上げること。
- **LCP は未導入**: DRM(LCP) 関連プロダクト（ReadiumLCP / AdapterLCPSQLite）は
  要件外のためリンクしない。

## ビルド環境に関する注意（この環境固有）

- この環境の Xcode 26.6 には **iOS 26.5 のプラットフォームランタイムが未インストール**
  （シミュレータランタイムも無し）。そのため `xcodebuild ... build` は
  「iOS 26.5 is not installed」で destination 解決に失敗し、iOS バイナリの
  完全ビルドはこの環境では実行できない。
- ただし **SPM のパッケージグラフ解決は成功**しており（Readium 3.10.0 と推移的依存が
  すべて checkout 済み）、`-showBuildSettings` でビルド設定も正しく解決される。
  実機/シミュレータランタイムを入れた環境ではそのままビルド可能な構成。

## Task 6.3 実装で検証した Readium 3.10 API（実ソース確認済み）

checkout パス:
`~/Library/Developer/Xcode/DerivedData/Dokusho-*/SourcePackages/checkouts/swift-toolkit/Sources`

### ローカル ePub を開くフロー（3.x）

1. `DefaultHTTPClient(configuration: .default)` を生成（`HTTPClient`）。
   - `AssetRetriever` の `resourceFactory` に必要。ローカルファイルでは HTTP は発火しない。
2. `AssetRetriever(httpClient:)` の convenience init を使用
   （`Shared/Toolkit/Data/Asset/AssetRetriever.swift:41`）。
3. `FileURL(url: fileURL)`（`Shared/Toolkit/URL/Absolute URL/FileURL.swift:13`、`init?`）
   で Foundation の file URL を `AbsoluteURL` へ変換。nil の場合はエラー。
4. `await assetRetriever.retrieve(url: fileURL)` → `Result<Asset, AssetRetrieveURLError>`。
5. `PublicationOpener(parser: EPUBParser())` を生成
   （`Streamer/PublicationOpener.swift:22`）。
   - **PDF 依存を避けるため `DefaultPublicationParser` は使わず `EPUBParser()` を直接渡す**。
     `DefaultPublicationParser` は `pdfFactory: PDFDocumentFactory` を要求するため。
   - `EPUBParser` は `PublicationParser` に準拠、`init(reflowablePositionsStrategy:)` は
     デフォルト引数のみで `EPUBParser()` で生成可（`Streamer/Parser/EPUB/EPUBParser.swift:31`）。
6. `await opener.open(asset: asset, allowUserInteraction: false)`
   → `Result<Publication, PublicationOpenError>`。

### Navigator

- `EPUBNavigatorViewController(publication:initialLocation:config:)` の
  convenience init（`Navigator/EPUB/EPUBNavigatorViewController.swift:278`、`throws`）を使用。
  **HTTP サーバーは不要**（`httpServer:` 付き init は `@deprecated`、「no longer needed」）。
- `config: EPUBNavigatorViewController.Configuration(preferences:defaults:...)`。
  今回は `preferences` のみ指定。

### プリファレンス（フォント・テーマ）

- `EPUBPreferences(fontSize: Double?, theme: Theme?, ...)`
  （`Navigator/EPUB/Preferences/EPUBPreferences.swift`）。
  - `fontSize` は 1.0 = 100%。
  - `Theme`（`Navigator/Preferences/Types.swift:63`）: `.light` / `.dark` / `.sepia`。
- 実行中の反映は `navigator.submitPreferences(_ preferences: EPUBPreferences)`
  （`Navigator/EPUB/EPUBNavigatorViewController.swift:905`、`Configurable` 準拠）。

### 進捗（locator）

- delegate は `EPUBNavigatorDelegate`。継承する
  `VisualNavigatorDelegate` / `SelectableNavigatorDelegate` / `NavigatorDelegate` の
  必須メソッドは**すべて default 実装あり**。実装が必要なのは
  `func navigator(_:locationDidChange:)` のみ（`Navigator/Navigator.swift:99`、default あり）。
- `Locator.locations.totalProgression: Double?`
  （`Shared/Publication/Locator.swift:143`）が 0.0〜1.0 の全体進捗。
  - ⚠️ **caveat**: reflowable ePub の totalProgression は端末幅・フォントサイズに依存する
    近似値。Komga のページ番号とは厳密対応しない（設計書 §10）。
    そのため Komga ページ = `round(totalProgression * (pagesCount-1)) + 1` の近似変換とする。

### 続きから読む（resume）

- `await publication.positions()` → `ReadResult<[Locator]>`
  （`Shared/Publication/Services/Positions/PositionsService.swift:95`、Publication の extension）。
  各 Locator の `locations.totalProgression` を持つ。
  target progression に最も近い position locator を初期 `initialLocation` に採用。
  positions が空／失敗時は `nil`（＝先頭から）にフォールバックせず先頭表示（明示的に nil）。
- resume の target progression は Komga の `readProgress.page`（1-based）から
  `(page - 1) / max(pagesCount - 1, 1)` で算出（設計書 §10 の近似）。

### 注意点

- `PublicationOpenError` / `AssetRetrieveURLError` は網羅的に日本語エラーメッセージへ変換する。
- `open`/`retrieve` は `async` かつ `Result` 返却（3.x は throwing でなく Result 型）。
- 本環境では iOS ランタイム未インストールのため完全ビルドは不可。型検査は checkout 済み
  ソースの実シグネチャに対して行い、API は実在確認済み。
