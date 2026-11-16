import XCTest

final class ContinueWatchingRemoteTests: XCTestCase {
    @MainActor
    func testRemoteOpensNextAvailableEpisodeAndContinuesToItsSuccessor() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview"]
        app.launch()
        let remote = XCUIRemote.shared
        let show = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "24, Next available · S01E03")
        ).firstMatch
        func moveDown(to target: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertTrue(target.waitForExistence(timeout: 12), app.debugDescription, file: file, line: line)
            for _ in 0..<5 {
                if target.hasFocus { return }
                remote.press(.down)
            }
            XCTAssertTrue(target.hasFocus, app.debugDescription, file: file, line: line)
        }
        moveDown(to: show)
        remote.press(.select)
        let third = app.staticTexts["24 · Season 1 · Episode 3"]
        XCTAssertTrue(third.waitForExistence(timeout: 10))
        let next = app.descendants(matching: .any).matching(identifier: "next-episode").firstMatch
        moveDown(to: next)
        XCTAssertEqual(next.label, "Next episode · S01E04")
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["24 · Season 1 · Episode 4"].waitForExistence(timeout: 10))
        XCTAssertFalse(next.exists)
        remote.press(.menu)
        XCTAssertTrue(third.waitForExistence(timeout: 10))
    }
}
