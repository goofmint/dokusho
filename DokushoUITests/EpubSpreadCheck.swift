import XCTest

/// Manual visual verification against demo/demo.epub (skipped when absent).
/// Live-rotates while reading, verifying each rotation via the window frame.
final class EpubSpreadCheck: XCTestCase {
    func testLiveRotationCycle() throws {
        let epubPath = "/Users/nakatsugawa/Code/MOONGIFT/dokusho/demo/demo.epub"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: epubPath))

        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        let app = XCUIApplication()
        app.launchArguments = ["-debugEpubReader"]
        app.launchEnvironment["EPUB_PATH"] = epubPath
        app.launchEnvironment["EPUB_PAGE"] = "3"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        sleep(8)
        try assertOrientation(app, portrait: true)
        add(shot("live-1-portrait"))

        XCUIDevice.shared.orientation = .landscapeLeft
        try waitOrientation(app, portrait: false)
        sleep(4)
        add(shot("live-2-landscape"))

        XCUIDevice.shared.orientation = .portrait
        try waitOrientation(app, portrait: true)
        sleep(4)
        add(shot("live-3-portrait-again"))
    }

    private func assertOrientation(_ app: XCUIApplication, portrait: Bool) throws {
        let frame = app.windows.firstMatch.frame
        XCTAssertEqual(frame.width < frame.height, portrait, "向きが想定外: \(frame)")
    }

    private func waitOrientation(_ app: XCUIApplication, portrait: Bool) throws {
        for _ in 0..<20 {
            let frame = app.windows.firstMatch.frame
            if (frame.width < frame.height) == portrait { return }
            usleep(500_000)
        }
        XCTFail("回転が反映されない: expectPortrait=\(portrait) frame=\(app.windows.firstMatch.frame)")
    }

    private func shot(_ n: String) -> XCTAttachment {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = n
        a.lifetime = .keepAlways
        return a
    }
}
