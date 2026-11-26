import XCTest

final class LibraryFeaturesNavigationTests: XCTestCase {
    @MainActor
    func testCreateEditCollectionAndChooseAlternateVersion() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-preview-library-features"]; app.launch()
        select(app.buttons["preview-collections"], app)
        enter("Weekend", into: app.textFields["collection-new-name"], app)
        select(app.buttons["collection-create"], app)
        let weekend = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Weekend,")).firstMatch
        select(weekend, app)
        select(app.buttons["collection-manage"], app)
        select(app.buttons["collection-member-Library Feature (2020).mp4"], app)
        select(app.buttons["collection-member-Library Sequel (2022).mp4"], app)
        capture("Personal collection membership", app)
        select(app.buttons["Done"], app)
        XCTAssertTrue(app.staticTexts["2 titles"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        capture("Personal collection with two titles", app)
        select(app.buttons["Rename"], app)
        let rename = app.textFields["collection-rename-name"]
        select(rename, app)
        // tvOS can still be applying injected keyboard events when typeText returns.
        // Observe each edit before dismissing the keyboard or saving a partial name.
        var previousName = "Weekend"
        while !previousName.isEmpty {
            rename.typeText(XCUIKeyboardKey.delete.rawValue)
            previousName.removeLast()
            if !previousName.isEmpty { waitForValue(previousName, in: rename, app) }
        }
        typeAcknowledged("Movie Night", into: rename, app)
        dismissKeyboard(app)
        select(app.buttons["Save name"], app)
        XCTAssertTrue(app.staticTexts["Movie Night"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        select(app.buttons["collection-manage"], app)
        select(app.buttons["collection-member-Library Sequel (2022).mp4"], app)
        select(app.buttons["Done"], app)
        XCTAssertTrue(app.staticTexts["1 title"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        capture("Renamed collection after removing a title", app)
        // A second fresh fixture exercises the actual file chooser and detail destination.
        app.terminate(); app.launch()
        select(app.buttons["preview-versions"], app)
        let cut = app.buttons["movie-version-Library Feature (2020) - Directors Cut.mp4"]
        XCTAssertTrue(cut.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Library Feature (2020).mp4"].exists, app.debugDescription)
        capture("Choose a clearly named edition with separate resume state", app)
        select(cut, app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Resume")).firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Library Feature (2020) - Directors Cut.mp4"].exists, app.debugDescription)
        // Exercise a secondary action after the navigation has settled; an
        // existence-only capture can occur during the push transition.
        select(app.buttons["Add to Watchlist"], app)
        XCTAssertTrue(app.buttons["Remove from Watchlist"].waitForExistence(timeout: 10), app.debugDescription)
        capture("Selected edition detail with readable secondary actions", app)
        select(app.buttons["Remove from Watchlist"], app)
        XCTAssertTrue(app.buttons["Add to Watchlist"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Resume 1:30")).firstMatch.exists,
                      "Watchlist changes must keep this edition's resume point.")
    }
    @MainActor private func enter(_ text: String, into field: XCUIElement, _ app: XCUIApplication) {
        select(field, app); typeAcknowledged(text, into: field, app); dismissKeyboard(app)
    }
    @MainActor private func typeAcknowledged(_ text: String, into field: XCUIElement, _ app: XCUIApplication) {
        var expected = ""
        for character in text {
            field.typeText(String(character)); expected.append(character)
            waitForValue(expected, in: field, app)
        }
    }
    @MainActor private func waitForValue(_ expected: String, in field: XCUIElement, _ app: XCUIApplication) {
        let applied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [applied], timeout: 5), .completed, app.debugDescription)
    }
    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor private func dismissKeyboard(_ app: XCUIApplication) {
        if app.keyboards.firstMatch.exists { XCUIRemote.shared.press(.menu) }
    }
    @MainActor private func select(_ target: XCUIElement, _ app: XCUIApplication) {
        XCTAssertTrue(target.waitForExistence(timeout: 15), app.debugDescription)
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == YES")).firstMatch
        func hasFocus() -> Bool {
            target.hasFocus || app.cells.containing(target.elementType, identifier: target.identifier.isEmpty ? target.label : target.identifier)
                .matching(NSPredicate(format: "hasFocus == YES")).firstMatch.exists
        }
        for _ in 0..<35 {
            if hasFocus() { break }
            if focused.exists, abs(focused.frame.midY - target.frame.midY) < 35 {
                XCUIRemote.shared.press(focused.frame.midX < target.frame.midX ? .right : .left)
            } else { XCUIRemote.shared.press(focused.exists && focused.frame.midY > target.frame.midY ? .up : .down) }
        }
        XCTAssertTrue(hasFocus(), app.debugDescription); XCUIRemote.shared.press(.select)
    }
}
