import SwiftUI
import KomgaKit

/// Temporary reader screen shown for ``ReaderDestination`` values.
///
/// **Phase 5 note:** replace this with the real image/ePub/PDF reader. The
/// destination carries the full ``KomgaBook`` (media profile, page count,
/// series id, read progress), and the shared ``PageImageLoader`` is available
/// via `services.imageLoader` for streaming page images.
struct ReaderPlaceholderView: View {
    let book: KomgaBook

    var body: some View {
        ContentUnavailableView {
            Label("リーダーは準備中です", systemImage: "book.pages")
        } description: {
            Text("「\(book.metadata.title.isEmpty ? book.name : book.metadata.title)」を読む機能は次のフェーズで実装されます。")
        }
        .navigationTitle("読む")
        .navigationBarTitleDisplayMode(.inline)
    }
}
