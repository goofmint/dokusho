import SwiftUI
import SwiftData

/// Settings screen. In Phase 3 it shows the current connection and provides the
/// disconnect (切断) action; cache/background-color settings arrive in Phase 7.
struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var services

    @Query private var serverConfigs: [ServerConfig]

    @State private var showDisconnectConfirmation = false
    @State private var disconnectError: String?

    private var serverConfig: ServerConfig? { serverConfigs.first }

    var body: some View {
        NavigationStack {
            Form {
                Section("接続情報") {
                    if let config = serverConfig {
                        LabeledContent("サーバー", value: config.serverName)
                        LabeledContent("URL", value: config.baseURL.absoluteString)
                    } else {
                        Text("サーバーに接続していません。")
                            .foregroundStyle(.secondary)
                    }
                }

                if serverConfig != nil {
                    Section {
                        Button("切断", role: .destructive) {
                            showDisconnectConfirmation = true
                        }
                    } footer: {
                        Text("サーバー情報とAPIキーを削除し、接続画面に戻ります。")
                    }
                }
            }
            .navigationTitle("設定")
            .confirmationDialog(
                "サーバーから切断しますか？",
                isPresented: $showDisconnectConfirmation,
                titleVisibility: .visible
            ) {
                Button("切断", role: .destructive, action: disconnect)
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("保存されたサーバー情報とAPIキーが削除されます。")
            }
            .alert(
                "切断に失敗しました",
                isPresented: Binding(
                    get: { disconnectError != nil },
                    set: { if !$0 { disconnectError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(disconnectError ?? "")
            }
        }
    }

    /// Removes the stored API key (Keychain) and `ServerConfig` (SwiftData) and
    /// clears the in-memory client, returning the app to the connection screen.
    private func disconnect() {
        do {
            try services.credentialStore.deleteAPIKey()
            for config in serverConfigs {
                modelContext.delete(config)
            }
            try modelContext.save()
            services.clearConnection()
        } catch {
            disconnectError = error.localizedDescription
        }
    }
}
