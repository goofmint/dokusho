import SwiftUI

/// End-of-book CTA shared by the image and ePub readers.
///
/// Placed outside each reader's HUD so it stays visible when the bars are
/// hidden. The accessibility identifier is distinct from "閉じる" and does
/// not include "送り" (the direction-toggle locator).
struct NextVolumePromptButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("次の巻を読む", systemImage: "book")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityIdentifier("reader.nextVolume")
        .accessibilityLabel("次の巻を読む")
    }
}
