import XCTest

final class HomeCollectionRemoteTests: XCTestCase {
    @MainActor
    private func focus(_ element: XCUIElement, in app: XCUIApplication,
                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), app.debugDescription, file: file, line: line)
        let remote = XCUIRemote.shared
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == YES")).firstMatch
        for _ in 0..<24 {
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
    private func assertFocusReturns(to element: XCUIElement, in app: XCUIApplication,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == YES"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 8), .completed, app.debugDescription, file: file, line: line)
    }

    @MainActor
    func testSeeAllReachesBeyondTheShelfAndReturnsToItsButton() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-home-collections"]
        app.launch()
        let remote = XCUIRemote.shared
        let seeAll = app.buttons["home-see-all-watchlist"]
        choose(seeAll, in: app)
        let title = app.staticTexts["home-collection-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(title.label, "Watchlist")
        XCTAssertEqual(app.staticTexts["home-collection-count"].label, "27 titles")
        // This is the 23rd grouped tile: the Home shelf stops at twenty.
        let lastFilm = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
                                                        "home-collection-item-", "Collection Film 20")).firstMatch
        for _ in 0..<14 {
            if lastFilm.exists { break }
            remote.press(.down)
        }
        choose(lastFilm, in: app)
        XCTAssertTrue(app.staticTexts["Collection Film 20"].waitForExistence(timeout: 10), app.debugDescription)
        remote.press(.menu)
        XCTAssertTrue(title.waitForExistence(timeout: 10), app.debugDescription)
        assertFocusReturns(to: lastFilm, in: app)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Apple TV complete Watchlist after returning from a title"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        remote.press(.menu)
        XCTAssertTrue(seeAll.waitForExistence(timeout: 10), app.debugDescription)
        assertFocusReturns(to: seeAll, in: app)

        choose(seeAll, in: app)
        let show = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
                                                    "home-collection-item-", "24, 2 seasons")).firstMatch
        choose(show, in: app)
        let seasonTwo = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Season 2")).firstMatch
        choose(seasonTwo, in: app)
        let episode = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "E2 ·")).firstMatch
        choose(episode, in: app)
        XCTAssertTrue(app.staticTexts["24 · Season 2 · Episode 2"].waitForExistence(timeout: 10), app.debugDescription)
        remote.press(.menu)
        remote.press(.menu)
        remote.press(.menu)
        XCTAssertTrue(title.waitForExistence(timeout: 10), app.debugDescription)
        assertFocusReturns(to: show, in: app)
        remote.press(.menu)
        assertFocusReturns(to: seeAll, in: app)
    }

    @MainActor
    func testRemovingLastWatchlistTitleKeepsDestinationAndRestoresUsableFocus() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-home-single-watchlist"]
        app.launch()
        let remote = XCUIRemote.shared
        choose(app.buttons["home-see-all-watchlist"], in: app)
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
                                                    "home-collection-item-", "Midnight Horizon")).firstMatch
        choose(card, in: app)
        choose(app.buttons["Remove from Watchlist"], in: app)
        XCTAssertTrue(app.buttons["Add to Watchlist"].waitForExistence(timeout: 8), app.debugDescription)
        remote.press(.menu)
        let title = app.staticTexts["home-collection-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(title.label, "Watchlist")
        XCTAssertEqual(app.staticTexts["home-collection-count"].label, "0 titles")
        XCTAssertTrue(app.staticTexts["Nothing here yet"].exists)
        assertFocusReturns(to: app.buttons["home-collection-back"], in: app)
        remote.press(.menu)
        assertFocusReturns(to: app.buttons["home-see-all-movie"], in: app)
    }
}
