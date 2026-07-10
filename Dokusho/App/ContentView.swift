import SwiftUI
import KomgaKit
import ReadiumNavigator

/// Placeholder root view for Phase 1.
///
/// Imports `KomgaKit` and `ReadiumNavigator` to prove both dependencies link
/// into the app target. Real navigation is built in Phase 3.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "books.vertical")
                .font(.largeTitle)
            Text("Dokusho")
                .font(.title)
            Text("KomgaKit \(KomgaKitVersion.current)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
