import Foundation
import Observation
import SwiftData
import KomgaKit

/// Drives the server connection screen: validates input, tests the connection
/// via `currentUser()`, and on success persists the config + API key.
@MainActor
@Observable
final class ConnectionViewModel {
    var urlText: String = ""
    var apiKey: String = ""

    private(set) var isConnecting = false
    /// User-facing (Japanese) error message, or `nil`.
    private(set) var errorMessage: String?

    /// Whether the 接続 button should be enabled.
    var canSubmit: Bool {
        !isConnecting
            && !urlText.trimmingCharacters(in: .whitespaces).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Attempts to connect. On success, persists to SwiftData + Keychain and
    /// activates the client on `services`.
    func connect(services: AppServices, modelContext: ModelContext) async {
        errorMessage = nil

        let trimmedURL = urlText.trimmingCharacters(in: .whitespaces)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespaces)

        guard let url = URL(string: trimmedURL), url.scheme != nil, url.host != nil else {
            errorMessage = "有効なURLを入力してください。"
            return
        }

        let config: KomgaServerConfig
        do {
            config = try KomgaServerConfig(baseURL: url, apiKey: trimmedKey)
        } catch {
            errorMessage = Self.message(for: error)
            return
        }

        isConnecting = true
        defer { isConnecting = false }

        let client = KomgaClient(config: config)
        do {
            _ = try await client.currentUser()
        } catch {
            errorMessage = Self.message(for: error)
            return
        }

        // Connection verified — persist and activate.
        // Snapshot the existing key first so a persistConfig failure can restore
        // it instead of destroying a previously working credential on a
        // re-connect. A load failure here is treated as "no previous key" (nil):
        // there was nothing usable to restore anyway. (`try?` flattens the
        // optional, so both a throw and a stored-nil collapse to nil.)
        let previousKey = try? services.credentialStore.loadAPIKey()
        do {
            try services.credentialStore.saveAPIKey(trimmedKey)
        } catch {
            errorMessage = Self.message(for: error)
            return
        }

        do {
            try persistConfig(url: url, modelContext: modelContext)
        } catch {
            // Undo the in-memory ServerConfig delete/insert, then restore the
            // previous key (or clear it if there was none) so a failed
            // re-connect leaves the prior working config and credential intact.
            modelContext.rollback()
            if let previousKey {
                try? services.credentialStore.saveAPIKey(previousKey)
            } else {
                try? services.credentialStore.deleteAPIKey()
            }
            errorMessage = Self.message(for: error)
            return
        }

        services.setConnected(client: client)
    }

    /// Replaces any existing single `ServerConfig` with the new one.
    private func persistConfig(url: URL, modelContext: ModelContext) throws {
        let existing = try modelContext.fetch(FetchDescriptor<ServerConfig>())
        for config in existing {
            modelContext.delete(config)
        }
        let serverName = url.host ?? url.absoluteString
        modelContext.insert(ServerConfig(baseURL: url, serverName: serverName))
        try modelContext.save()
    }

    /// Maps errors to Japanese user-facing messages per design.md §5.1.
    static func message(for error: Error) -> String {
        if let komgaError = error as? KomgaError {
            switch komgaError {
            case .invalidAPIKey:
                return "APIキーが正しくありません。設定を確認してください。"
            case .forbidden:
                return "アクセス権限がありません。"
            case .notFound:
                return "サーバーが見つかりませんでした。URLを確認してください。"
            case .clientError(let status):
                return "リクエストが不正です (コード \(status))。アプリの更新が必要かもしれません。"
            case .serverError(let status):
                return "サーバーエラーが発生しました (コード \(status))。時間をおいて再試行してください。"
            case .unexpectedStatus(let status):
                return "予期しない応答です (コード \(status))。"
            case .network:
                return "サーバーに接続できません。ネットワーク接続とURLを確認してください。"
            case .decoding:
                return "サーバーの応答を解釈できませんでした。Komgaのバージョンを確認してください。"
            case .insecureURL:
                return "URLはhttpsで指定してください。http接続は許可されていません。"
            }
        }
        if let credentialError = error as? CredentialStoreError {
            return credentialError.errorDescription ?? "APIキーの保存に失敗しました。"
        }
        return error.localizedDescription
    }
}
