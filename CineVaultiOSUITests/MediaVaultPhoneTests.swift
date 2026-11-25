import XCTest

final class MediaVaultPhoneTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testConnectAndImportWebDAVFromSources() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-empty-library"]
        app.launch()

        let manage = app.tabBars.buttons["Manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 15))
        manage.tap()
        app.buttons["manage-media-sources"].tap()
        app.buttons["Add NAS"].tap()
        let connect = app.buttons["Connect WebDAV"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        connect.tap()
        let address = app.textFields["HTTPS WebDAV address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        let guest = app.switches["source-guest-access"]
        XCTAssertTrue(guest.waitForExistence(timeout: 10))
        // The SwiftUI accessibility element includes the label and switch.
        guest.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(guest.value as? String, "0")

        let name = app.textFields["Library name"]
        name.tap()
        name.typeText("Fixture media")
        address.tap()
        let endpoint = "https://127.0.0.1:15443/dav/"
        address.typeText(endpoint)
        let addressAccepted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", endpoint), object: address)
        XCTAssertEqual(XCTWaiter.wait(for: [addressAccepted], timeout: 5), .completed,
                       "The connection form must acknowledge the complete fixture address before saving.")

        let username = app.textFields["source-username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        username.tap()
        username.typeText("cinevault")
        let password = app.secureTextFields["source-password"]
        password.tap()
        password.typeText("fixture-only")

        let save = app.buttons["source-save-and-scan"]
        XCTAssertTrue(save.isHittable)
        save.tap()
        let savedSource = app.staticTexts["Fixture media"]
        let connectionMessage = app.staticTexts["source-connection-message"]
        let connectedOrFailed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            savedSource.exists || connectionMessage.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [connectedOrFailed], timeout: 25), .completed,
                       "The source connection did not complete or report an error.")
        if connectionMessage.exists {
            capture("WebDAV connection failed before saving", app)
            XCTFail("WebDAV connection failed before saving: \(connectionMessage.label)")
            return
        }
        XCTAssertTrue(savedSource.exists, "Expected the authenticated source to be saved.")

        let scan = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "1 item · Scanned ")).firstMatch
        XCTAssertTrue(scan.waitForExistence(timeout: 25), app.debugDescription)

        // A completed scan can appear while the nested source-editor sheets are
        // still dismissing. Wait for the actual Sources screen before changing tabs.
        let sources = app.navigationBars["Sources"]
        XCTAssertTrue(sources.waitForExistence(timeout: 10))
        let editorClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [editorClosed], timeout: 10), .completed)
        dismissFixturePasswordPrompt(app)
        let library = app.tabBars.buttons["Library"]
        XCTAssertTrue(library.isHittable)
        library.tap()
        if dismissFixturePasswordPrompt(app), !library.isSelected {
            // The system can present its password sheet in response to the first
            // navigation tap. Only resume that observed interrupted action.
            XCTAssertTrue(library.isHittable)
            library.tap()
        }
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: library)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 10), .completed, app.debugDescription)
        capture("Library after authenticated WebDAV import", app)
        let poster = app.buttons["Film"]
        XCTAssertTrue(poster.waitForExistence(timeout: 10), app.debugDescription)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: poster)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, app.debugDescription)
        poster.tap()
        XCTAssertTrue(app.staticTexts["Film"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["Play"].exists, app.debugDescription)
        capture("Imported WebDAV movie opens its playback details", app)
    }

    @MainActor @discardableResult
    private func dismissFixturePasswordPrompt(_ app: XCUIApplication) -> Bool {
        // iOS may offer to save the synthetic WebDAV credentials after the form
        // closes. Keep that normal product behavior; decline only in this test.
        let prompt = app.sheets["Save Password?"]
        guard prompt.waitForExistence(timeout: 3) else { return false }
        let notNow = prompt.buttons["Not Now"]
        XCTAssertTrue(notNow.isHittable, app.debugDescription)
        notNow.tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: prompt)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed, app.debugDescription)
        return true
    }

    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + " accessibility"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }

    @MainActor
    func testViewerOnlySeesAllowedTitlesOnPhone() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-household"]
        app.launch()

        let kids = app.buttons["household-profile-Kids"]
        XCTAssertTrue(kids.waitForExistence(timeout: 30))
        kids.tap()

        XCTAssertTrue(app.tabBars.buttons["Profile"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.buttons["Manage"].exists)
        XCTAssertTrue(app.staticTexts["Family Adventure"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Restricted Feature"].exists)
        XCTAssertFalse(app.staticTexts["Unrated Feature"].exists)
    }

    @MainActor
    func testNativePlaybackAndSubtitleControls() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-playback", "--ui-preview-production-controls"]
        app.launch()

        let playing = app.staticTexts["fixture-native-playback-ready"]
        XCTAssertTrue(playing.waitForExistence(timeout: 25), "The native player should advance using the local SMB fixture.")
        let subtitles = app.buttons["playback-subtitles"]
        XCTAssertTrue(subtitles.waitForExistence(timeout: 5))
        subtitles.tap()
        XCTAssertTrue(app.buttons["subtitles-off"].waitForExistence(timeout: 10))
    }
}
