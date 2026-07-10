import SwiftUI

/// Top-level navigation sections, shared between the iPhone `TabView` and the
/// iPad `NavigationSplitView` sidebar.
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case home
    case library
    case collections
    case readLists
    case downloads
    case settings

    var id: String { rawValue }

    /// Localized (Japanese) title.
    var title: String {
        switch self {
        case .home: return "ホーム"
        case .library: return "ライブラリ"
        case .collections: return "コレクション"
        case .readLists: return "リードリスト"
        case .downloads: return "ダウンロード"
        case .settings: return "設定"
        }
    }

    /// SF Symbol used for tab items and sidebar rows.
    var systemImage: String {
        switch self {
        case .home: return "house"
        case .library: return "books.vertical"
        case .collections: return "square.stack"
        case .readLists: return "list.bullet.rectangle"
        case .downloads: return "arrow.down.circle"
        case .settings: return "gearshape"
        }
    }

    /// The destination view for this section.
    @ViewBuilder
    var destination: some View {
        switch self {
        case .home: HomeView()
        case .library: LibraryView()
        case .collections: CollectionsView()
        case .readLists: ReadListsView()
        case .downloads: DownloadsView()
        case .settings: SettingsView()
        }
    }
}
