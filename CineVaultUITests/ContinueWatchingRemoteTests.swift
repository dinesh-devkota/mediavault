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
        XCTAssertTrue(show.waitForExistence(timeout: 12), app.debugDescription)
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == YES")).firstMatch
        let focusedCard = app.buttons.matching(
            NSPredicate(format: "hasFocus == YES AND identifier BEGINSWITH %@", "continue-watching-")
        ).firstMatch
        // The Home tab sits above the middle of the horizontal shelf. Down can land on a movie.
        for _ in 0..<4 {
            if focusedCard.exists { break }
            remote.press(focused.exists && focused.frame.midY > show.frame.midY ? .up : .down)
        }
        XCTAssertTrue(focusedCard.exists, app.debugDescription)
        for _ in 0..<5 {
            if show.hasFocus { break }
            remote.press(.left)
        }
        XCTAssertTrue(show.hasFocus, app.debugDescription)
        remote.press(.select)
        let third = app.staticTexts["24 · Season 1 · Episode 3"]
        XCTAssertTrue(third.waitForExistence(timeout: 10))
        let next = app.descendants(matching: .any).matching(identifier: "next-episode").firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<6 {
            if next.hasFocus { break }
            if focused.exists && focused.frame.minX > next.frame.maxX {
                remote.press(.left)
            } else {
                remote.press(focused.exists && focused.frame.midY > next.frame.midY ? .up : .down)
            }
        }
        XCTAssertTrue(next.hasFocus, app.debugDescription)
        XCTAssertEqual(next.label, "Next episode · S01E04")
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["24 · Season 1 · Episode 4"].waitForExistence(timeout: 10))
        XCTAssertFalse(next.exists)
        remote.press(.menu)
        XCTAssertTrue(third.waitForExistence(timeout: 10))
    }
}
