import SwiftUI

/// The connected app shell. Chooses a layout by horizontal size class:
/// compact (iPhone / iPad slide-over) → `TabView`; regular (iPad) →
/// `NavigationSplitView` with a sidebar. Both drive the same ``AppSection`` set.
struct MainView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if horizontalSizeClass == .regular {
            SidebarLayout()
        } else {
            TabLayout()
        }
    }
}

/// iPhone / compact layout: bottom tab bar.
private struct TabLayout: View {
    var body: some View {
        TabView {
            ForEach(AppSection.allCases) { section in
                section.destination
                    .tabItem {
                        Label(section.title, systemImage: section.systemImage)
                    }
                    .tag(section)
            }
        }
    }
}

/// iPad / regular layout: sidebar + detail.
private struct SidebarLayout: View {
    @State private var selection: AppSection? = .home

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                NavigationLink(value: section) {
                    Label(section.title, systemImage: section.systemImage)
                }
            }
            .navigationTitle("Dokusho")
        } detail: {
            if let selection {
                selection.destination
            } else {
                ContentUnavailableView(
                    "セクションを選択",
                    systemImage: "sidebar.left",
                    description: Text("左のサイドバーから項目を選んでください。")
                )
            }
        }
    }
}
