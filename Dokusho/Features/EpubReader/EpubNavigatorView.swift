import SwiftUI
import UIKit
import ReadiumNavigator
import ReadiumShared

/// `EPUBNavigatorViewController` を SwiftUI に埋め込むラッパー。
///
/// navigator の生成は ViewModel が担い、ここでは表示と delegate 中継のみを行う。
struct EpubNavigatorView: UIViewControllerRepresentable {
    let navigator: EPUBNavigatorViewController
    /// locator 変化時に呼ばれるハンドラ。
    let onLocationChange: @MainActor (Locator) -> Void
    /// navigator から報告されたエラーのハンドラ。
    let onError: @MainActor (NavigatorError) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLocationChange: onLocationChange, onError: onError)
    }

    func makeUIViewController(context: Context) -> EPUBNavigatorViewController {
        navigator.delegate = context.coordinator
        return navigator
    }

    func updateUIViewController(_ uiViewController: EPUBNavigatorViewController, context: Context) {
        context.coordinator.onLocationChange = onLocationChange
        context.coordinator.onError = onError
    }

    /// navigator の delegate を受けて SwiftUI 側へ橋渡しする。
    @MainActor
    final class Coordinator: NSObject, EPUBNavigatorDelegate {
        var onLocationChange: @MainActor (Locator) -> Void
        var onError: @MainActor (NavigatorError) -> Void

        init(
            onLocationChange: @escaping @MainActor (Locator) -> Void,
            onError: @escaping @MainActor (NavigatorError) -> Void
        ) {
            self.onLocationChange = onLocationChange
            self.onError = onError
        }

        func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
            onLocationChange(locator)
        }

        func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
            onError(error)
        }
    }
}
