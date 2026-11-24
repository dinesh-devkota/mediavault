import XCTest

final class SearchRemoteTests: XCTestCase {
    @MainActor
    func testMenuReturnsToTheSelectedEpisodeSeasonAndSearchResult() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-search-input"]
        app.launch()

        let remote = XCUIRemote.shared
        let show = "8 seasons · 192 episodes"
        let season = "Season 2"
        let episode = "E2 · Day 2 · Hour 2"

        // SwiftUI combines a card's title and subtitle into its accessible label.
        func card(_ label: String) -> XCUIElement {
            app.buttons.matching(
                NSPredicate(format: "label CONTAINS %@", label)
            ).firstMatch
        }
        func assertFocus(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
            let target = card(label)
            XCTAssertTrue(target.waitForExistence(timeout: 8), app.debugDescription, file: file, line: line)
            // Wait for the card to appear, then observe its focus as layout settles.
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == YES"), object: target)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 8), .completed,
                           "Expected remote focus on \(label).\n\(app.debugDescription)", file: file, line: line)
        }
        func navigateHorizontally(to label: String) {
            let target = card(label)
            // A simulator directional press can move more than one card. Establish
            // the intended initial selection without weakening the Back assertions.
            for _ in 0..<4 {
                if target.hasFocus { break }
                let focused = app.buttons.matching(NSPredicate(format: "hasFocus == YES")).firstMatch
                guard focused.exists else { break }
                remote.press(focused.frame.midX < target.frame.midX ? .right : .left)
                let arrived = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == YES"), object: target)
                if XCTWaiter.wait(for: [arrived], timeout: 2) == .completed { break }
            }
            assertFocus(label)
        }

        let field = app.searchFields["Titles, shows, episodes, genres, files"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        field.typeText("24")
        XCTAssertTrue(app.staticTexts["1 result"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(field.value as? String, "24")
        // Move from the system keyboard to the grouped show.
        for _ in 0..<6 {
            if card(show).exists && card(show).hasFocus { break }
            remote.press(.down)
        }
        assertFocus(show)
        remote.press(.select)
        assertFocus("Season 1")
        navigateHorizontally(to: season)
        remote.press(.select)
        assertFocus("E1 · Day 2 · Hour 1")
        navigateHorizontally(to: episode)
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["24 · Season 2 · Episode 2"].waitForExistence(timeout: 8))

        remote.press(.menu)
        assertFocus(episode)
        remote.press(.menu)
        assertFocus(season)
        remote.press(.menu)
        assertFocus(show)
        XCTAssertTrue(app.staticTexts["1 result"].exists)
    }
}
