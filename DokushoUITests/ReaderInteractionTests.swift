import XCTest

/// Interaction tests for the image reader, driven through the DEBUG-only
/// `-debugPdfReader` harness (a locally generated 6-page PDF, no server).
///
/// These encode the user-facing tap contract:
/// - center tap: show/hide header AND progress bar together
/// - bottom-strip tap: toggle ONLY the progress bar
/// - left/right thirds: page turns (not asserted here; covered indirectly)
final class ReaderInteractionTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterLaunch()
    }

    private func continueAfterLaunch() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-debugPdfReader"]
        app.launch()
        // Wait for the harness to render the first page (HUD hidden initially,
        // so wait on the app window instead of a specific element).
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        sleep(2)
    }

    /// The progress slider only exists while the progress bar is shown.
    private var slider: XCUIElement { app.sliders.firstMatch }
    /// The close button only exists while the header is shown. Matched by the
    /// explicit accessibility label set in ImageReaderScreen.
    private var closeButton: XCUIElement { app.buttons["閉じる"].firstMatch }
    /// The reader title in the header.
    private var headerTitle: XCUIElement { app.staticTexts["Harness PDF"].firstMatch }

    private func tapCenter() {
        app.windows.firstMatch.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).tap()
    }

    /// Taps inside the bottom 20% strip but above where the progress bar sits,
    /// so the same spot toggles the bar both on and off.
    private func tapBottomStrip() {
        app.windows.firstMatch.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)
        ).tap()
    }

    func testCenterTapTogglesFullHUD() throws {
        XCTAssertFalse(slider.exists, "初期状態では進捗バーは非表示のはず")
        XCTAssertFalse(closeButton.exists, "初期状態ではヘッダーは非表示のはず")

        tapCenter()
        XCTAssertTrue(closeButton.waitForExistence(timeout: 3), "中央タップでヘッダーが表示されるはず")
        XCTAssertTrue(slider.exists, "中央タップで進捗バーも表示されるはず")

        tapCenter()
        sleep(1)
        XCTAssertFalse(closeButton.exists, "再度の中央タップでヘッダーが消えるはず")
        XCTAssertFalse(slider.exists, "再度の中央タップで進捗バーも消えるはず")
    }

    func testBottomStripTogglesProgressOnly() throws {
        tapBottomStrip()
        XCTAssertTrue(slider.waitForExistence(timeout: 3), "下部タップで進捗バーが表示されるはず")
        XCTAssertFalse(closeButton.exists, "下部タップではヘッダーは表示されないはず")

        tapBottomStrip()
        sleep(1)
        XCTAssertFalse(slider.exists, "再度の下部タップで進捗バーが消えるはず")
    }

    func testDirectionToggleReachableFromHeader() throws {
        tapCenter()
        XCTAssertTrue(closeButton.waitForExistence(timeout: 3))
        // The direction toggle carries the progression label (左送り/右送り).
        let direction = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '送り'")
        ).firstMatch
        XCTAssertTrue(direction.exists, "ヘッダーに読み方向トグルがあるはず")
        direction.tap()
        // Still present (and tappable) after toggling.
        XCTAssertTrue(direction.exists)
    }
}
