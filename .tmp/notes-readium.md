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
