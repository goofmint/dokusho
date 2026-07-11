import Foundation

/// ePub リーダーで発生しうるエラー。
///
/// すべてのケースがユーザー向けの日本語メッセージを持つ。空ビューやサイレント
/// フォールバックは行わず、失敗時は必ずこのエラーで明示する。
enum EpubReaderError: Error, Equatable {
    /// ダウンロード済みのはずの ePub ファイルが見つからない。
    case fileMissing(path: String)
    /// ファイルは存在するが Readium が扱えるアセットとして解決できなかった。
    case assetUnreadable(detail: String)
    /// アセットは取得できたが Publication として解析できなかった（破損・非対応など）。
    case publicationOpenFailed(detail: String)
    /// Navigator の初期化に失敗した。
    case navigatorInitFailed(detail: String)

    /// ユーザーに表示する見出し。
    var title: String {
        switch self {
        case .fileMissing:
            return "ファイルが見つかりません"
        case .assetUnreadable:
            return "ファイルを読み込めません"
        case .publicationOpenFailed:
            return "ePub を開けません"
        case .navigatorInitFailed:
            return "ビューアを初期化できません"
        }
    }

    /// ユーザーに表示する詳細説明。原因の手掛かりを含める。
    var message: String {
        switch self {
        case let .fileMissing(path):
            return "ダウンロード済みの ePub ファイルが見つかりませんでした。"
                + "再ダウンロードが必要な可能性があります。\n対象: \(path)"
        case let .assetUnreadable(detail):
            return "ファイルの読み込みに失敗しました。ファイルが破損しているか、"
                + "対応していない形式の可能性があります。\n詳細: \(detail)"
        case let .publicationOpenFailed(detail):
            return "ePub の解析に失敗しました。ファイルが破損しているか、"
                + "対応していない ePub の可能性があります。\n詳細: \(detail)"
        case let .navigatorInitFailed(detail):
            return "ビューアの初期化に失敗しました。\n詳細: \(detail)"
        }
    }
}
