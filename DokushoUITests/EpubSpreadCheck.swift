import XCTest
final class EpubSpreadCheck: XCTestCase {
    func testDemoEpubPortraitAndLandscape() throws {
        let epubPath = "/Users/nakatsugawa/Code/MOONGIFT/dokusho/demo/demo.epub"
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: epubPath),
            "demo/demo.epub がある環境でのみ実行する手動検証テスト"
        )
        let app = XCUIApplication()
        app.launchArguments = ["-debugEpubReader"]
        app.launchEnvironment["EPUB_PATH"] = epubPath
        app.launchEnvironment["EPUB_PAGE"] = "3"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        XCUIDevice.shared.orientation = .portrait
        sleep(10) // 45MB epub: allow detection + first page render
        add(shot("demo-portrait"))
        // Advance a few pages so the landscape spread shows a real page pair.
        let center = app.windows.firstMatch
        center.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.4)).tap()
        sleep(1)
        center.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.4)).tap()
        sleep(2)
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(6)
        add(shot("demo-landscape"))
    }
    private func shot(_ n: String) -> XCTAttachment {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = n; a.lifetime = .keepAlways; return a
    }
}
