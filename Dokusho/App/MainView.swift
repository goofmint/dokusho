import SwiftUI

/// The connected app shell. Chooses a layout by horizontal size class:
/// compact (iPhone / iPad slide-over) → `TabView`; regular (iPad) →
/// `NavigationSplitView` with a sidebar. Both drive the same ``AppSection`` set.
struct MainView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(AppServices.self) private var services
    @Environment(ReaderPresentation.self) private var readerPresentation

    var body: some View {
        @Bindable var readerPresentation = readerPresentation

        Group {
            if horizontalSizeClass == .regular {
                SidebarLayout()
            } else {
                TabLayout()
            }
        }
        .fullScreenCover(
            item: $readerPresentation.presentedBook,
            onDismiss: finishReaderDismissal
        ) { book in
            NavigationStack {
                ReaderRootView(book: book)
            }
        }
    }

    /// Flushes reader progress before allowing book details to refresh or
    /// another online reader to be presented.
    private func finishReaderDismissal() {
        Task {
            await services.progressSyncer?.flushOutstanding()
            readerPresentation.didCompleteDismissal()
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
