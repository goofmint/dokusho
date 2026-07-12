import SwiftUI
import SwiftData

/// Settings screen (Phase 7).
///
/// Groups: cache (usage / limit / clear), reader (background color, default
/// reading direction), downloads (total size + management), connection (server
/// info + disconnect with optional data deletion), and app info (version).
///
/// All user preferences persist via `@AppStorage` (UserDefaults); secrets stay
/// in the Keychain. Cache-limit changes propagate to the live ``PageImageLoader``
/// through ``AppServices/applyCacheLimit(_:)``.
struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var services

    @Query private var serverConfigs: [ServerConfig]

    // MARK: Persisted preferences

    @AppStorage(CacheLimit.storageKey) private var cacheLimitBytes = CacheLimit.defaultValue.rawValue
    @AppStorage(ReaderBackground.storageKey) private var backgroundRaw = ReaderBackground.defaultValue.rawValue
    @AppStorage(ReadingDirectionDefault.storageKey) private var directionRaw = ReadingDirectionDefault.defaultValue.rawValue

    // MARK: Transient UI state

    /// Current on-disk cache size in bytes; `nil` until first measured.
    @State private var cacheUsageBytes: Int?
    @State private var isClearingCache = false
    @State private var showClearCacheConfirmation = false

    @State private var showDisconnectConfirmation = false
    @State private var showReconnectSheet = false
    @State private var deleteDownloadsOnDisconnect = false
    @State private var deleteCacheOnDisconnect = false
    @State private var disconnectError: String?

    private var serverConfig: ServerConfig? { serverConfigs.first }

    var body: some View {
        NavigationStack {
            Form {
                cacheSection
                readerSection
                downloadsSection
                connectionSection
                appInfoSection
            }
            .navigationTitle("設定")
            .task { await refreshCacheUsage() }
            .confirmationDialog(
                "キャッシュを削除しますか？",
                isPresented: $showClearCacheConfirmation,
                titleVisibility: .visible
            ) {
                Button("削除", role: .destructive) { Task { await clearCache() } }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("ダウンロード済みのブックには影響しません。ページ画像とサムネイルの一時キャッシュのみ削除されます。")
            }
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

    // MARK: - Cache

    private var cacheSection: some View {
        Section("キャッシュ") {
            LabeledContent("使用量") {
                if let cacheUsageBytes {
                    Text(byteString(cacheUsageBytes))
                } else {
                    ProgressView()
                }
            }

            Picker("上限", selection: cacheLimitSelection) {
                ForEach(CacheLimit.allCases) { limit in
                    Text(limit.label).tag(limit)
                }
            }

            Button(role: .destructive) {
                showClearCacheConfirmation = true
            } label: {
                if isClearingCache {
                    ProgressView()
                } else {
                    Text("キャッシュを削除")
                }
            }
            .disabled(isClearingCache)
        }
    }

    /// Binds the picker to the `CacheLimit` enum while persisting its raw bytes,
    /// and pushes the change to the live loader.
    private var cacheLimitSelection: Binding<CacheLimit> {
        Binding(
            get: { CacheLimit(rawValue: cacheLimitBytes) ?? CacheLimit.defaultValue },
            set: { newValue in
                cacheLimitBytes = newValue.rawValue
                services.applyCacheLimit(newValue.rawValue)
                Task { await refreshCacheUsage() }
            }
        )
    }

    // MARK: - Reader

    private var readerSection: some View {
        Section("リーダー設定") {
            Picker("背景色", selection: backgroundSelection) {
                ForEach(ReaderBackground.allCases) { background in
                    Text(background.label).tag(background)
                }
            }

            Picker("既定の読み方向", selection: directionSelection) {
                ForEach(ReadingDirectionDefault.allCases) { direction in
                    Text(direction.label).tag(direction)
                }
            }
        }
    }

    private var backgroundSelection: Binding<ReaderBackground> {
        Binding(
            get: { ReaderBackground(rawValue: backgroundRaw) ?? ReaderBackground.defaultValue },
            set: { backgroundRaw = $0.rawValue }
        )
    }

    private var directionSelection: Binding<ReadingDirectionDefault> {
        Binding(
            get: { ReadingDirectionDefault(rawValue: directionRaw) ?? ReadingDirectionDefault.defaultValue },
            set: { directionRaw = $0.rawValue }
        )
    }

    // MARK: - Downloads

    private var downloadsSection: some View {
        Section("ダウンロード") {
            if let downloadManager = services.downloadManager {
                LabeledContent(
                    "合計サイズ",
                    value: byteString(downloadManager.totalDownloadedSize())
                )
            }
            NavigationLink {
                DownloadsList()
                    .navigationTitle("ダウンロード")
            } label: {
                Label("ダウンロードを管理", systemImage: "arrow.down.circle")
            }
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Group {
            Section("接続情報") {
                if let config = serverConfig {
                    LabeledContent("サーバー", value: config.serverName)
                    LabeledContent("URL", value: config.baseURL.absoluteString)
                    Button("サーバー設定を変更") {
                        showReconnectSheet = true
                    }
                } else {
                    Text("サーバーに接続していません。")
                        .foregroundStyle(.secondary)
                }
            }
            .sheet(isPresented: $showReconnectSheet) {
                ConnectionView(initialURLText: serverConfig?.baseURL.absoluteString ?? "")
            }

            if serverConfig != nil {
                Section {
                    Toggle("ダウンロード済みのブックも削除", isOn: $deleteDownloadsOnDisconnect)
                    Toggle("キャッシュも削除", isOn: $deleteCacheOnDisconnect)
                    Button("切断", role: .destructive) {
                        showDisconnectConfirmation = true
                    }
                } header: {
                    Text("切断")
                } footer: {
                    Text("サーバー情報とAPIキーを削除し、接続画面に戻ります。上のスイッチでダウンロードやキャッシュの削除も選べます。")
                }
            }
        }
    }

    // MARK: - App info

    private var appInfoSection: some View {
        Section("アプリ情報") {
            LabeledContent("バージョン", value: appVersionString)
            LabeledContent("ビルド日時", value: buildDateString)
        }
    }

    /// e.g. "1.0 (1)". Reads `CFBundleShortVersionString` / `CFBundleVersion`;
    /// shows "-" only if the bundle omits them entirely (no silent guess).
    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?): return "\(short) (\(build))"
        case let (short?, nil): return short
        case let (nil, build?): return build
        case (nil, nil): return "-"
        }
    }

    /// When the running binary was built, so "which build is on this device?"
    /// is answerable at a glance (the version string alone doesn't change
    /// between development builds).
    private var buildDateString: String {
        guard
            let url = Bundle.main.executableURL,
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        else {
            return "-"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Actions

    private func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func refreshCacheUsage() async {
        guard let imageLoader = services.imageLoader else {
            cacheUsageBytes = 0
            return
        }
        cacheUsageBytes = await imageLoader.diskUsage()
    }

    private func clearCache() async {
        guard let imageLoader = services.imageLoader else { return }
        isClearingCache = true
        await imageLoader.clearCache()
        await refreshCacheUsage()
        isClearingCache = false
    }

    /// Removes the stored API key (Keychain) and `ServerConfig` (SwiftData), then
    /// clears the in-memory client. Optionally deletes downloads and/or cache per
    /// the confirmation toggles. Returns the app to the connection screen.
    private func disconnect() {
        Task { await performDisconnect() }
    }

    /// Performs the disconnect teardown. If deleting downloads (the only step
    /// that can report a failure) throws, sets ``disconnectError`` and ABORTS
    /// without removing the API key / `ServerConfig` / in-memory client, so the
    /// user is not left half-disconnected with orphaned files. Always clears the
    /// browse cache on a successful disconnect so a later, different server can
    /// never reuse this server's cached lists.
    @MainActor
    private func performDisconnect() async {
        if deleteDownloadsOnDisconnect, let downloadManager = services.downloadManager {
            do {
                for record in downloadManager.allRecords() {
                    try downloadManager.delete(bookID: record.bookID)
                }
            } catch {
                disconnectError = "ダウンロード済みブックの削除に失敗したため、切断を中止しました。（\(error.localizedDescription)）"
                return
            }
        }

        if deleteCacheOnDisconnect, let imageLoader = services.imageLoader {
            await imageLoader.clearCache()
        }

        // Always drop the browse cache as part of teardown.
        await BrowseCache.shared.clear()

        do {
            try services.credentialStore.deleteAPIKey()
            for config in serverConfigs {
                modelContext.delete(config)
            }
            try modelContext.save()
        } catch {
            disconnectError = "接続情報の削除に失敗しました。（\(error.localizedDescription)）"
            return
        }
        services.clearConnection()
    }
}
