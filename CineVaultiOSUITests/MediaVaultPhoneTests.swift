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
        selectLibraryAfterFixtureImport(app)
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

    @MainActor
    private func selectLibraryAfterFixtureImport(_ app: XCUIApplication) {
        let library = app.tabBars.buttons["Library"]
        let prompt = app.sheets["Save Password?"]
        // Use one navigation budget even if iOS begins presenting its password
        // window before its sheet becomes accessible or after the first tap.
        let deadline = Date().addingTimeInterval(10)
        var needsTap = true
        var handledPasswordInterruption = false
        // The password offer can appear and disappear entirely inside tap(),
        // consuming that touch before our between-action queries can see it.
        // Let XCTest provide the actual interrupting element, including a
        // system-owned window, and only decline the known synthetic-login offer.
        let monitor = addUIInterruptionMonitor(withDescription: "Decline fixture password saving") { element in
            guard element.label == "Save Password?" || element.staticTexts["Save Password?"].exists,
                  element.buttons["Not Now"].exists,
                  element.buttons["Save"].exists else { return false }
            element.buttons["Not Now"].tap()
            handledPasswordInterruption = true
            return true
        }
        defer { removeUIInterruptionMonitor(monitor) }
        func waitFor(_ predicate: NSPredicate, object: Any? = nil) -> Bool {
            // XCUI queries and taps wait for app quiescence themselves. The
            // preceding action may have completed while consuming the remaining
            // budget, so observe its result before deciding whether to wait more.
            if predicate.evaluate(with: object) { return true }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            let expectation = XCTNSPredicateExpectation(predicate: predicate, object: object)
            let result = XCTWaiter.wait(for: [expectation], timeout: remaining)
            if result == .completed { return true }
            return result == .timedOut && predicate.evaluate(with: object)
        }
        while true {
            let ready = NSPredicate { _, _ in
                prompt.exists || library.isSelected || (needsTap && library.isHittable)
            }
            guard waitFor(ready) else {
                capture("Library navigation did not become actionable", app)
                XCTFail("Library did not become actionable or selected within the navigation budget.")
                return
            }
            if prompt.exists {
                // Decline only the observed system offer for synthetic credentials.
                let notNow = prompt.buttons["Not Now"]
                guard waitFor(NSPredicate(format: "hittable == true"), object: notNow) else {
                    capture("Password prompt did not become actionable", app)
                    XCTFail("The observed password prompt did not expose its Not Now action.")
                    return
                }
                notNow.tap()
                guard waitFor(NSPredicate(format: "exists == false"), object: prompt) else {
                    capture("Password prompt did not close", app)
                    XCTFail("The observed password prompt did not close.")
                    return
                }
                // A second tab tap is allowed only after this actual interruption.
                needsTap = !library.isSelected
            } else if library.isSelected {
                return
            } else if needsTap && library.isHittable {
                handledPasswordInterruption = false
                library.tap()
                // Only an explicitly handled interruption permits another tap;
                // a genuine navigation failure still uses the original budget.
                needsTap = handledPasswordInterruption && !library.isSelected
            }
        }
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
