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
    /// ナビゲーター上のタップ。第1引数はビュー相対座標、第2引数はビューの高さ。
    let onTap: @MainActor (CGPoint, CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLocationChange: onLocationChange, onError: onError, onTap: onTap)
    }

    func makeUIViewController(context: Context) -> EPUBNavigatorViewController {
        navigator.delegate = context.coordinator
        context.coordinator.bindActivateObserver(to: navigator)
        return navigator
    }

    func updateUIViewController(_ uiViewController: EPUBNavigatorViewController, context: Context) {
        context.coordinator.onLocationChange = onLocationChange
        context.coordinator.onError = onError
        context.coordinator.onTap = onTap
    }

    static func dismantleUIViewController(
        _ uiViewController: EPUBNavigatorViewController,
        coordinator: Coordinator
    ) {
        coordinator.unbindActivateObserver()
    }

    /// navigator の delegate を受けて SwiftUI 側へ橋渡しする。
    @MainActor
    final class Coordinator: NSObject, EPUBNavigatorDelegate {
        var onLocationChange: @MainActor (Locator) -> Void
        var onError: @MainActor (NavigatorError) -> Void
        var onTap: @MainActor (CGPoint, CGFloat) -> Void
        /// Readium の活性化オブザーバー。破棄時に `removeObserver` で明示解除する。
        private var activateObserverToken: InputObservableToken?
        private weak var boundNavigator: EPUBNavigatorViewController?

        init(
            onLocationChange: @escaping @MainActor (Locator) -> Void,
            onError: @escaping @MainActor (NavigatorError) -> Void,
            onTap: @escaping @MainActor (CGPoint, CGFloat) -> Void
        ) {
            self.onLocationChange = onLocationChange
            self.onError = onError
            self.onTap = onTap
        }

        deinit {
            // DirectionalNavigationAdapter と同じ方針: トークン破棄だけでは
            // 登録は残るので、navigator に対して明示的に解除する。
            guard let navigator = boundNavigator, let token = activateObserverToken else {
                return
            }
            Task { @MainActor [weak navigator] in
                navigator?.removeObserver(token)
            }
        }

        func bindActivateObserver(to navigator: EPUBNavigatorViewController) {
            unbindActivateObserver()
            boundNavigator = navigator
            activateObserverToken = navigator.addObserver(.activate { [weak self] event in
                guard let self, let navigator = self.boundNavigator else {
                    return false
                }
                self.onTap(event.location, navigator.view.bounds.height)
                return true
            })
        }

        func unbindActivateObserver() {
            if let navigator = boundNavigator, let token = activateObserverToken {
                navigator.removeObserver(token)
            }
            activateObserverToken = nil
            boundNavigator = nil
        }

        func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
            onLocationChange(locator)
        }

        func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
            onError(error)
        }
    }
}
