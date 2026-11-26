import XCTest

final class MediaVaultPhoneTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testOneDriveSetupEntryValidatesClientIDAndReturnsWithoutConnecting() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-empty-library"]
        app.launch()

        let manage = app.tabBars.buttons["Manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 15))
        manage.tap()
        app.buttons["manage-media-sources"].tap()
        app.buttons["Add NAS"].tap()
        let connect = app.buttons["add-onedrive-source"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        connect.tap()

        let client = app.textFields["onedrive-client"]
        let signIn = app.buttons["onedrive-sign-in"]
        XCTAssertTrue(client.waitForExistence(timeout: 10))
        XCTAssertTrue(signIn.exists)
        XCTAssertFalse(signIn.isEnabled, "An empty registration must not start an account connection.")
        client.tap()
        client.typeText("invalid")
        let invalidAccepted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "invalid"), object: client)
        XCTAssertEqual(XCTWaiter.wait(for: [invalidAccepted], timeout: 5), .completed)
        XCTAssertFalse(signIn.isEnabled)

        // A synthetic identifier validates the real phone form without beginning
        // OAuth or contacting a live Microsoft account.
        let fixtureID = "00000000-0000-4000-8000-000000000001"
        client.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7) + fixtureID)
        let validAccepted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", fixtureID), object: client)
        XCTAssertEqual(XCTWaiter.wait(for: [validAccepted], timeout: 5), .completed)
        XCTAssertTrue(signIn.isEnabled)
        capture("OneDrive phone setup accepts a valid public client identifier", app)

        let navigation = app.navigationBars["Connect OneDrive"]
        XCTAssertTrue(navigation.exists)
        navigation.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["Connect WebDAV"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Sources"].waitForExistence(timeout: 10))
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
        openImportedWebDAVMovie(in: app)
    }

    @MainActor
    private func openImportedWebDAVMovie(in app: XCUIApplication) {
        let library = app.tabBars.buttons["Library"]
        let poster = app.buttons["Film"]
        let title = app.staticTexts["Film"]
        let play = app.buttons["Play"]
        let promptTitle = "Save Password?"
        let prompt = app.sheets[promptTitle]
        let deadline = Date().addingTimeInterval(25)
        var declinedPasswordOffer = false

        func waitFor(_ condition: @escaping () -> Bool) -> Bool {
            // A preceding XCTest action may reach the target while using the last of the budget.
            if condition() { return true }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            let predicate = NSPredicate { _, _ in condition() }
            let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
            let result = XCTWaiter.wait(for: [expectation], timeout: remaining)
            return result == .completed || (result == .timedOut && condition())
        }

        func decline(_ sheet: XCUIElement) -> Bool {
            guard !declinedPasswordOffer, deadline.timeIntervalSinceNow > 0, sheet.exists,
                  sheet.label == promptTitle || sheet.staticTexts[promptTitle].exists else { return false }
            let notNow = sheet.buttons["Not Now"]
            let savePassword = sheet.buttons["Save"]
            guard waitFor({ notNow.exists && notNow.isHittable && savePassword.exists }),
                  deadline.timeIntervalSinceNow > 0 else { return false }
            notNow.tap()
            guard waitFor({ !sheet.exists }) else { return false }
            declinedPasswordOffer = true
            return true
        }

        // Keep the monitor through the poster touch and the resulting playback controls.
        // A late system password sheet can appear after Library is already selected.
        let monitor = addUIInterruptionMonitor(withDescription: "Decline fixture password saving") { element in
            let sheet = element.elementType == .sheet ? element : element.sheets[promptTitle]
            return decline(sheet)
        }
        defer { removeUIInterruptionMonitor(monitor) }

        func advance(target: @escaping () -> Bool, actionable: @escaping () -> Bool, tap: () -> Bool) -> Bool {
            var mayTap = true
            while waitFor({ prompt.exists || target() || (mayTap && actionable()) }) {
                if prompt.exists {
                    guard decline(prompt) else { return false }
                    mayTap = true
                } else if target() {
                    return true
                } else {
                    guard mayTap, deadline.timeIntervalSinceNow > 0 else { return false }
                    let previouslyDeclined = declinedPasswordOffer
                    guard tap() else { return false }
                    // Another touch is permitted only when the known password offer consumed this one.
                    mayTap = !previouslyDeclined && declinedPasswordOffer
                }
            }
            return false
        }

        guard advance(target: { library.isSelected }, actionable: { library.isHittable }, tap: {
            library.tap()
            return true
        }) else {
            capture("Library navigation did not become actionable", app)
            XCTFail("Library did not become selected after handling any fixture password offer.")
            return
        }
        capture("Library after authenticated WebDAV import", app)

        var touchedPoster = false
        guard advance(target: { touchedPoster && title.exists && play.exists && play.isEnabled && play.isHittable },
                      actionable: { poster.exists && poster.isEnabled }, tap: {
            if poster.isHittable {
                touchedPoster = true
                poster.tap()
                return true
            }
            // A visible SwiftUI tile may lack an XCTest hit point. Touch only within its verified frame.
            let frame = poster.frame
            let window = app.windows.firstMatch
            guard window.exists, frame.width >= 44, frame.height >= 44,
                  window.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return false }
            touchedPoster = true
            poster.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            return true
        }) else {
            capture("WebDAV poster touch did not open actionable Film details", app)
            XCTFail("The imported Film must open from a visible poster touch and show an actionable Play button.")
            return
        }
        capture("Imported WebDAV movie opens its playback details", app)
    }

    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + " accessibility"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }

    @MainActor
    func testPrivacyPolicyIsReadableFromTheLockedProfilePicker() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-household"]
        app.launch()

        let policy = app.buttons.matching(NSPredicate(format: "label == %@", "Privacy policy")).firstMatch
        XCTAssertTrue(policy.waitForExistence(timeout: 15), app.debugDescription)
        policy.tap()
        let intro = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@",
            "This policy applies to the official MediaVault app.")).firstMatch
        XCTAssertTrue(intro.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Restricted Feature"].exists)
        XCTAssertFalse(app.tabBars.buttons["Profile"].exists)

        let navigation = app.navigationBars["Privacy policy"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 10), app.debugDescription)
        navigation.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["household-profile-Admin"].waitForExistence(timeout: 10), app.debugDescription)
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
