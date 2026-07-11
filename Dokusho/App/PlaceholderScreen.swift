import SwiftUI

/// Simple "coming soon" placeholder used by feature screens that other agents /
/// later phases will fill in. Wraps its content in a `NavigationStack` so each
/// section gets a navigation bar with its title.
struct PlaceholderScreen: View {
    let title: String
    let systemImage: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                title,
                systemImage: systemImage,
                description: Text("この画面は今後のフェーズで実装されます。")
            )
            .navigationTitle(title)
        }
    }
}
