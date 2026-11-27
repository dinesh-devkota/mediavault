import XCTest

final class DriveCompanionRemoteTests: XCTestCase {
    @MainActor
    func testOwnerPairsSavesAndReconnectsGoogleDrive() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let endpoint = "https://127.0.0.1:18477"
        app.launchArguments = ["--ui-test-empty-library"]
        app.launchEnvironment["MEDIA_VAULT_DRIVE_COMPANION_URL"] = endpoint
        app.launch()

        select(app.buttons["Sources"], in: app)
        select(app.buttons["source-add-google-drive-companion"], in: app)
        select(app.buttons["drive-companion-start"], in: app)
        assertPairing(endpoint, in: app)
        assertOneSelectedFile(in: app)
        let save = app.buttons["drive-companion-save"]
        XCTAssertEqual(save.label, "Save and scan")
        select(save, in: app)

        let scanned = app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@",
            "drive-companion-scan-result", "1 item · Scanned")).firstMatch
        XCTAssertTrue(scanned.waitForExistence(timeout: 30), app.debugDescription)
        let edits = app.buttons.matching(identifier: "drive-companion-edit")
        XCTAssertEqual(edits.count, 1, app.debugDescription)
        select(edits.firstMatch, in: app)

        select(app.buttons["drive-companion-reconnect"], in: app)
        assertPairing(endpoint, in: app)
        assertOneSelectedFile(in: app)
        XCTAssertEqual(save.label, "Reconnect and scan")
        select(save, in: app)
        XCTAssertTrue(edits.firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertFalse(save.exists, app.debugDescription)
        XCTAssertEqual(edits.count, 1, app.debugDescription)
        XCTAssertTrue(scanned.waitForExistence(timeout: 30), app.debugDescription)
    }

    @MainActor
    private func assertPairing(_ endpoint: String, in app: XCUIApplication, line: UInt = #line) {
        let code = app.staticTexts["drive-companion-code"]
        XCTAssertTrue(code.waitForExistence(timeout: 12), app.debugDescription, line: line)
        XCTAssertEqual(code.label, "AB23-CD45", app.debugDescription, line: line)
        let address = app.staticTexts["drive-companion-verification-url"]
        XCTAssertTrue(address.label.hasPrefix(endpoint + "/"), app.debugDescription, line: line)
        XCTAssertTrue(app.buttons["drive-companion-cancel"].exists, app.debugDescription, line: line)
    }

    @MainActor
    private func assertOneSelectedFile(in app: XCUIApplication, line: UInt = #line) {
        let count = app.staticTexts["drive-companion-selected-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 15), app.debugDescription, line: line)
        XCTAssertEqual(count.label, "1 file selected in Google Drive", app.debugDescription, line: line)
    }

    @MainActor
    private func select(_ target: XCUIElement, in app: XCUIApplication, line: UInt = #line) {
        XCTAssertTrue(target.waitForExistence(timeout: 15), app.debugDescription, line: line)
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == YES")).firstMatch
        func hasFocus() -> Bool {
            target.hasFocus || app.cells.containing(target.elementType, identifier: target.identifier.isEmpty ? target.label : target.identifier)
                .matching(NSPredicate(format: "hasFocus == YES")).firstMatch.exists
        }
        let remote = XCUIRemote.shared
        for _ in 0..<25 {
            if hasFocus() { break }
            if focused.exists, abs(focused.frame.midY - target.frame.midY) < 35 {
                remote.press(focused.frame.midX < target.frame.midX ? .right : .left)
            } else {
                remote.press(focused.exists && focused.frame.midY > target.frame.midY ? .up : .down)
            }
        }
        XCTAssertTrue(hasFocus(), app.debugDescription, line: line)
        XCTAssertTrue(target.isEnabled, app.debugDescription, line: line)
        remote.press(.select)
    }
}
