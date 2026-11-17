import XCTest

final class BulkWatchRemoteTests: XCTestCase {
    @MainActor
    private func focus(_ element: XCUIElement, in app: XCUIApplication,
                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), app.debugDescription, file: file, line: line)
        let remote = XCUIRemote.shared
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == YES")).firstMatch
        for _ in 0..<18 {
            if element.hasFocus { return }
            if !focused.exists { remote.press(.down); continue }
            let target = element.frame, current = focused.frame
            if current.maxY < target.minY { remote.press(.down) }
            else if current.minY > target.maxY { remote.press(.up) }
            else { remote.press(current.midX < target.midX ? .right : .left) }
        }
        XCTAssertTrue(element.hasFocus, app.debugDescription, file: file, line: line)
    }

    @MainActor
    private func choose(_ element: XCUIElement, in app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        focus(element, in: app, file: file, line: line)
        XCUIRemote.shared.press(.select)
    }

    @MainActor
    func testLibrarySelectionCanCancelThenMarkTwoFiles() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-bulk"]
        app.launch()
        choose(app.buttons["bulk-watch-open"], in: app)
        XCTAssertTrue(app.staticTexts["0 of 6 files selected"].waitForExistence(timeout: 8))
        choose(app.buttons["bulk-watch-all"], in: app)
        XCTAssertTrue(app.staticTexts["6 of 6 files selected"].exists)
        XCUIRemote.shared.press(.menu)
        choose(app.buttons["bulk-watch-open"], in: app)
        XCTAssertTrue(app.staticTexts["0 of 6 files selected"].waitForExistence(timeout: 8))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "bulk-watch-row-"))
        // The selection list creates offscreen rows lazily. Verify the rows being changed.
        XCTAssertGreaterThanOrEqual(rows.count, 2)
        XCTAssertFalse(rows.allElementsBoundByIndex.contains { $0.label.contains("Watched ·") })
        let firstID = rows.element(boundBy: 0).identifier
        let secondID = rows.element(boundBy: 1).identifier
        choose(app.buttons[firstID], in: app)
        choose(app.buttons[secondID], in: app)
        XCTAssertTrue(app.staticTexts["2 of 6 files selected"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Apple TV selected library files"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        choose(app.buttons["bulk-watch-watched"], in: app)
        let result = app.descendants(matching: .any).matching(identifier: "bulk-watch-result").firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(result.label, "Marked 2 files watched.")
        choose(app.buttons["bulk-watch-open"], in: app)
        XCTAssertTrue(app.staticTexts["0 of 6 files selected"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons[firstID].label.contains("Watched ·"))
        XCTAssertTrue(app.buttons[secondID].label.contains("Watched ·"))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["bulk-watch-open"].waitForExistence(timeout: 8))
    }

    @MainActor
    func testSeasonActionKeepsTheOtherSeasonUnwatched() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-bulk-show"]
        app.launch()
        let seasonOne = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Season 1")).firstMatch
        let seasonTwo = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Season 2")).firstMatch
        choose(seasonOne, in: app)
        choose(app.buttons["bulk-watch-open"], in: app)
        XCTAssertTrue(app.staticTexts["24 · Season 1"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["2 of 2 files selected"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Apple TV whole season watched action"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        choose(app.buttons["bulk-watch-watched"], in: app)
        let result = app.descendants(matching: .any).matching(identifier: "bulk-watch-result").firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(result.label, "Marked 2 files watched.")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "E1 · Day 1", "Watched")).firstMatch.waitForExistence(timeout: 8), app.debugDescription)
        let updated = XCTAttachment(screenshot: app.screenshot())
        updated.name = "Apple TV watched season after saving"
        updated.lifetime = .keepAlways
        add(updated)
        XCUIRemote.shared.press(.menu)
        choose(seasonTwo, in: app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "E1 · Day 2", "Episode")).firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "E1 · Day 2", "Watched")).firstMatch.exists)
    }
}
