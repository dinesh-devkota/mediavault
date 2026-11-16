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
        func focusedCard(_ label: String) -> XCUIElement {
            app.descendants(matching: .any).matching(
                NSPredicate(format: "hasFocus == YES AND label CONTAINS %@", label)
            ).firstMatch
        }
        func assertFocus(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertTrue(focusedCard(label).waitForExistence(timeout: 8),
                          "Expected remote focus on \(label).\n\(app.debugDescription)", file: file, line: line)
        }

        let field = app.searchFields["Titles, shows, episodes, genres, files"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        field.typeText("24")
        XCTAssertTrue(app.staticTexts["1 result"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(field.value as? String, "24")
        // Move from the system keyboard to the grouped show.
        for _ in 0..<6 {
            if focusedCard(show).exists { break }
            remote.press(.down)
        }
        assertFocus(show)
        remote.press(.select)
        assertFocus("Season 1")
        remote.press(.right)
        assertFocus(season)
        remote.press(.select)
        assertFocus("E1 · Day 2 · Hour 1")
        remote.press(.right)
        assertFocus(episode)
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
