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
        rename.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7) + "Movie Night")
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
        capture("Selected edition detail and resume action", app)
    }
    @MainActor private func enter(_ text: String, into field: XCUIElement, _ app: XCUIApplication) {
        select(field, app); field.typeText(text); dismissKeyboard(app)
    }
    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor private func dismissKeyboard(_ app: XCUIApplication) {
        if app.keyboards.buttons["Done"].exists { app.keyboards.buttons["Done"].tap() }
        else if app.keyboards.buttons["Return"].exists { app.keyboards.buttons["Return"].tap() }
    }
    @MainActor private func select(_ target: XCUIElement, _ app: XCUIApplication) {
        XCTAssertTrue(target.waitForExistence(timeout: 15), app.debugDescription)
        for _ in 0..<5 where !target.isHittable { app.swipeUp() }
        XCTAssertTrue(target.isHittable, app.debugDescription); target.tap()
    }
}
