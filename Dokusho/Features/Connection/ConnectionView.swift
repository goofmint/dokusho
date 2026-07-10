import SwiftUI
import SwiftData

/// Full-screen server connection form shown when the app is not connected.
///
/// Collects the server URL + API key, validates https, tests the connection,
/// and on success persists the config (SwiftData) and API key (Keychain).
struct ConnectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: ConnectionViewModel

    /// - Parameter initialURLText: Pre-fills the URL field (used when
    ///   re-configuring from Settings). The API key is never pre-filled.
    init(initialURLText: String = "") {
        let viewModel = ConnectionViewModel()
        viewModel.urlText = initialURLText
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        NavigationStack {
            Form {
                Section {
                    TextField("https://komga.example.com", text: $viewModel.urlText)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("APIキー", text: $viewModel.apiKey)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("サーバー情報")
                } footer: {
                    Text("KomgaサーバーのURL（https必須）とAPIキーを入力してください。")
                }

                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(action: submit) {
                        HStack {
                            Spacer()
                            if viewModel.isConnecting {
                                ProgressView()
                            } else {
                                Text("接続")
                            }
                            Spacer()
                        }
                    }
                    .disabled(!viewModel.canSubmit)
                }
            }
            .navigationTitle("サーバーに接続")
        }
    }

    private func submit() {
        Task {
            await viewModel.connect(services: services, modelContext: modelContext)
            // When shown as a sheet (re-configuration from Settings), close on
            // success. As the root connection screen this is a harmless no-op.
            if services.isConnected {
                dismiss()
            }
        }
    }
}
