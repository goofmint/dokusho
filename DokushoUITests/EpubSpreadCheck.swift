import XCTest

/// Manual visual verification against demo/demo.epub (skipped when absent).
/// Live-rotates while reading, verifying each rotation via the window frame.
final class EpubSpreadCheck: XCTestCase {
    /// Path of the verification ePub. The book is copyrighted, so it cannot be
    /// bundled as a test resource; it is resolved portably instead:
    /// 1. an `EPUB_PATH` environment variable on the test runner, when set;
    /// 2. otherwise `demo/demo.epub` relative to the repository root, derived
    ///    from this file's compile-time `#filePath`.
    private static let epubPath: String = {
        if let override = ProcessInfo.processInfo.environment["EPUB_PATH"], !override.isEmpty {
            return override
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DokushoUITests/
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("demo/demo.epub")
            .path
    }()

    func testLiveRotationCycle() throws {
        let epubPath = Self.epubPath
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
