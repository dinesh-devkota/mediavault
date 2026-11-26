import XCTest

final class HouseholdRemoteTests: XCTestCase {
    @MainActor
    func testRemoteProfileSwitchHidesRestrictedTitlesAndBackgroundLocks() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-preview-household"]; app.launch()
        let kids = app.buttons["household-profile-Kids"]
        XCTAssertTrue(kids.waitForExistence(timeout: 30), app.debugDescription)
        capture("Household profile picker", app)
        select(kids, app)
        XCTAssertTrue(app.staticTexts["Family Adventure"].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Restricted Feature"].exists)
        XCTAssertFalse(app.staticTexts["Unrated Feature"].exists)
        XCTAssertFalse(app.staticTexts["Private Memory"].exists)
        XCTAssertFalse(app.buttons["Sources"].exists)
        capture("Kids library contains only allowed rated media", app)
        select(app.buttons["household-switch"], app)
        XCTAssertTrue(kids.waitForExistence(timeout: 10))
        select(app.buttons["household-profile-Guest"], app)
        XCTAssertTrue(app.staticTexts["No media available for this profile yet"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Family Adventure"].exists)
        capture("Empty profile explains how to get access", app)
        XCUIRemote.shared.press(.home)
        app.activate()
        XCTAssertTrue(kids.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Family Adventure"].exists)
        capture("Returning to MediaVault requires profile selection", app)
    }

    @MainActor
    func testAdminPINSheetBackDoesNotUnlock() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-preview-household"]; app.launch()
        let admin = app.buttons["household-profile-Admin"]
        XCTAssertTrue(admin.waitForExistence(timeout: 30))
        select(admin, app)
        XCTAssertTrue(app.secureTextFields["household-unlock-pin"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Restricted Feature"].exists)
        capture("Admin PIN sheet", app)
        XCUIRemote.shared.press(.menu)
        if app.secureTextFields["household-unlock-pin"].exists { XCUIRemote.shared.press(.menu) }
        XCTAssertTrue(admin.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Restricted Feature"].exists)
        capture("Back safely returns to profile picker", app)
    }

    @MainActor
    func testAdminUnlockReachesViewerPermissions() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-preview-household"]; app.launch()
        select(app.buttons["household-profile-Admin"], app)
        let field = app.secureTextFields["household-unlock-pin"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        select(field, app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        field.typeText("328614")
        XCUIRemote.shared.press(.menu)
        select(app.buttons["household-unlock"], app)
        XCTAssertTrue(app.buttons["household-switch"].waitForExistence(timeout: 15), app.debugDescription)
        select(app.buttons["Settings"], app)
        select(app.buttons["household-settings"], app)
        select(app.buttons["household-edit-Kids"], app)
        XCTAssertTrue(app.staticTexts["household-folder-permissions"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.secureTextFields["household-authorize-pin"].exists, app.debugDescription)
        capture("Admin viewer folder and rating permissions", app)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["household-add-viewer"].waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor
    func testOwnerReachesPlexLinkSetupAndCanBackOut() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ui-preview-household"]; app.launch()
        select(app.buttons["household-profile-Admin"], app)
        let field = app.secureTextFields["household-unlock-pin"]
        select(field, app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        field.typeText("328614")
        XCUIRemote.shared.press(.menu)
        select(app.buttons["household-unlock"], app)
        XCTAssertTrue(app.buttons["household-switch"].waitForExistence(timeout: 15), app.debugDescription)
        select(app.buttons["Sources"], app)
        select(app.buttons["source-add-plex"], app)
        XCTAssertTrue(app.buttons["plex-link-start"].waitForExistence(timeout: 10), app.debugDescription)
        capture("Plex linking entry is reachable by remote", app)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["source-add-plex"].waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor
    private func select(_ target: XCUIElement, _ app: XCUIApplication) {
        XCTAssertTrue(target.waitForExistence(timeout: 10), app.debugDescription)
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == YES")).firstMatch
        func hasFocus() -> Bool {
            target.hasFocus || app.cells.containing(target.elementType, identifier: target.identifier.isEmpty ? target.label : target.identifier)
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
    @MainActor
    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
