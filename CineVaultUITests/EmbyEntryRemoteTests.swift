import XCTest

final class EmbyEntryRemoteTests: XCTestCase {
    @MainActor
    func testRemoteOpensEmbySetupAndRequiresAServerBeforeSignIn() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-emby-entry"]
        app.launch()
        select(app.buttons["add-emby-source"], in: app)
        XCTAssertTrue(app.textFields["emby-server-address"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.secureTextFields["emby-password"].exists)
        XCTAssertFalse(app.buttons["emby-connect"].isEnabled)

        let username = app.textFields["emby-username"]
        select(username, in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        username.typeText("fixture")
        XCUIRemote.shared.press(.menu)
        select(app.buttons["emby-connect"], in: app)
        XCTAssertTrue(app.staticTexts["Enter the complete HTTPS address for your Emby server."].waitForExistence(timeout: 10),
                      app.debugDescription)
        XCTAssertFalse(app.buttons["emby-add-library"].exists)
    }

    @MainActor
    private func select(_ target: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(target.waitForExistence(timeout: 10), app.debugDescription)
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == YES")).firstMatch
        func hasFocus() -> Bool {
            target.hasFocus || app.cells.containing(target.elementType, identifier: target.identifier)
                .matching(NSPredicate(format: "hasFocus == YES")).firstMatch.exists
        }
        for _ in 0..<25 {
            if hasFocus() { break }
            if focused.exists, abs(focused.frame.midY - target.frame.midY) < 35 {
                XCUIRemote.shared.press(focused.frame.midX < target.frame.midX ? .right : .left)
            } else { XCUIRemote.shared.press(focused.exists && focused.frame.midY > target.frame.midY ? .up : .down) }
        }
        XCTAssertTrue(hasFocus(), app.debugDescription)
        XCUIRemote.shared.press(.select)
    }
}
