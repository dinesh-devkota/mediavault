import XCTest

final class PlaybackTimeRemoteTests: XCTestCase {
    @MainActor
    func testResumeDetailsShowTimeRemaining() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-detail"]
        app.launch()
        let remaining = app.staticTexts["playback-remaining-time"]
        XCTAssertTrue(remaining.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertEqual(remaining.label, "About 1h 15m left")
        XCTAssertTrue(app.buttons["Resume 30:00"].exists, app.debugDescription)
        XCTAssertTrue(app.buttons["Start Over"].exists, app.debugDescription)
    }
}
