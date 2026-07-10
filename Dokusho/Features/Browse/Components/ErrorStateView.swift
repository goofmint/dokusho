import SwiftUI
import KomgaKit

/// A full-region error placeholder with a retry action, per design §5.2 (list
/// screens show a retryable error view in the content area).
struct ErrorStateView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("読み込みに失敗しました", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("再試行", action: retry)
                .buttonStyle(.borderedProminent)
        }
    }
}

/// Maps errors into user-facing Japanese messages. ``KomgaError`` cases get
/// specific guidance; anything else falls back to a generic message.
enum ErrorMessage {
    static func text(for error: Error) -> String {
        switch error {
        case let komga as KomgaError:
            return message(for: komga)
        default:
            return "予期しないエラーが発生しました。"
        }
    }

    private static func message(for error: KomgaError) -> String {
        switch error {
        case .invalidAPIKey:
            return "APIキーが無効です。設定から再接続してください。"
        case .forbidden:
            return "この操作を行う権限がありません。"
        case .notFound:
            return "サーバーから削除された可能性があります。"
        case .serverError:
            return "サーバーでエラーが発生しました。しばらくして再試行してください。"
        case .network:
            return "ネットワークに接続できません。接続を確認してください。"
        case .decoding:
            return "サーバーの応答を解釈できませんでした。バージョンが非互換の可能性があります。"
        case .insecureURL:
            return "安全でない接続です。https のURLを使用してください。"
        }
    }
}
