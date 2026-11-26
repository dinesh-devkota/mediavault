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
        guard XCTWaiter.wait(for: [connectedOrFailed], timeout: 25) == .completed else {
            capture("WebDAV did not report a connection result", app)
            XCTFail("The source connection did not complete or report an error.")
            return
        }
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

    @MainActor
    func testLinkPlexAndImportLibraryFromSources() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-empty-library", "--ui-test-plex-fixture"]
        app.launch()

        let manage = app.tabBars.buttons["Manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 15))
        manage.tap()
        let sources = app.buttons["manage-media-sources"]
        XCTAssertTrue(sources.waitForExistence(timeout: 10))
        sources.tap()
        let plex = app.buttons["source-add-plex"]
        XCTAssertTrue(plex.waitForExistence(timeout: 10))
        plex.tap()
        let link = app.buttons["plex-link-start"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()
        XCTAssertTrue(app.staticTexts["plex-link-code"].waitForExistence(timeout: 20), app.debugDescription)

        let server = app.buttons["Fixture Plex"]
        XCTAssertTrue(server.waitForExistence(timeout: 45), "Expected Plex fixture approval and discovery. \(app.debugDescription)")
        server.tap()
        let section = app.buttons["Fixture Movies"]
        XCTAssertTrue(section.waitForExistence(timeout: 30), app.debugDescription)
        section.tap()

        let scan = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "2 items · Scanned ")).firstMatch
        XCTAssertTrue(scan.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Fixture Movies"].exists)
        XCTAssertTrue(app.navigationBars["Sources"].waitForExistence(timeout: 10))
        selectLibraryAfterFixtureImport(app)
        let poster = app.buttons["Fixture Movie"]
        XCTAssertTrue(poster.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<3 where !poster.isHittable { app.swipeUp() }
        XCTAssertTrue(poster.isHittable, app.debugDescription)
        poster.tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor
    func testConnectOneDriveDeviceCodeAndImportSelectedFolder() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-empty-library", "--ui-test-onedrive"]
        app.launch()

        let manage = app.tabBars.buttons["Manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 15))
        manage.tap()
        app.buttons["manage-media-sources"].tap()
        app.buttons["Add NAS"].tap()
        let connect = app.buttons["add-onedrive-source"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10), app.debugDescription)
        connect.tap()
        let registration = app.textFields["onedrive-client"]
        XCTAssertTrue(registration.waitForExistence(timeout: 10))
        registration.tap()
        let clientID = "15cf518d-e2a1-46b0-b260-34bb4dd6c758"
        registration.typeText(clientID)
        let valid = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", clientID), object: registration)
        XCTAssertEqual(XCTWaiter.wait(for: [valid], timeout: 5), .completed)
        let signIn = app.buttons["onedrive-sign-in"]
        XCTAssertTrue(signIn.isEnabled)
        if !signIn.isHittable { app.swipeUp() }
        XCTAssertTrue(signIn.isHittable)
        signIn.tap()

        let code = app.staticTexts["onedrive-user-code"]
        XCTAssertTrue(code.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertEqual(code.label, "OD-PHONE")
        let movies = app.buttons["Open Movies"]
        XCTAssertTrue(movies.waitForExistence(timeout: 25), app.debugDescription)
        movies.tap()
        XCTAssertTrue(app.staticTexts["Movies"].waitForExistence(timeout: 10))
        let save = app.buttons["onedrive-use-folder"]
        XCTAssertTrue(save.isHittable, app.debugDescription)
        save.tap()

        let scan = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "1 item · Scanned ")).firstMatch
        XCTAssertTrue(scan.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertTrue(app.navigationBars["Sources"].waitForExistence(timeout: 10))
        selectLibraryAfterFixtureImport(app)
        let film = app.buttons["OneDrive Journey"]
        XCTAssertTrue(film.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<3 where !film.isHittable { app.swipeUp() }
        XCTAssertTrue(film.isHittable, app.debugDescription)
        film.tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 10), app.debugDescription)
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
    func testConnectDropboxAndImportSelectedFolder() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-empty-library", "--ui-test-dropbox"]
        app.launch()

        let manage = app.tabBars.buttons["Manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 15))
        manage.tap()
        app.buttons["manage-media-sources"].tap()
        app.buttons["Add NAS"].tap()
        let connect = app.buttons["add-dropbox-source"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10), app.debugDescription)
        connect.tap()
        let key = app.textFields["dropbox-app-key"]
        XCTAssertTrue(key.waitForExistence(timeout: 10), app.debugDescription)
        key.tap()
        key.typeText("fixture-app")
        app.buttons["dropbox-begin"].tap()

        let browser = app.buttons["dropbox-open-browser"]
        XCTAssertTrue(browser.waitForExistence(timeout: 10), app.debugDescription)
        let code = app.secureTextFields["dropbox-approval-code"]
        code.tap()
        code.typeText("fixture-code")
        let verify = app.buttons["dropbox-verify"]
        if !verify.isHittable { app.swipeUp() }
        XCTAssertTrue(verify.isHittable, app.debugDescription)
        verify.tap()

        let folder = app.buttons["Open Media"]
        XCTAssertTrue(folder.waitForExistence(timeout: 15), app.debugDescription)
        folder.tap()
        let useFolder = app.buttons["dropbox-use-folder"]
        XCTAssertTrue(useFolder.waitForExistence(timeout: 15), app.debugDescription)
        useFolder.tap()

        let scan = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "2 items · Scanned ")).firstMatch
        XCTAssertTrue(scan.waitForExistence(timeout: 25), app.debugDescription)
        let library = app.tabBars.buttons["Library"]
        library.tap()
        let film = app.buttons["Film"]
        XCTAssertTrue(film.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<3 where !film.isHittable { app.swipeUp() }
        XCTAssertTrue(film.isHittable, app.debugDescription)
        film.tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor
    func testGoogleDriveFilesSetupOffersScopedPicker() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-empty-library"]
        app.launch()
        let manage = app.tabBars.buttons["Manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 15))
        manage.tap()
        app.buttons["manage-media-sources"].tap()
        app.buttons["Add NAS"].tap()
        let connect = app.buttons["Connect Google Drive via Files"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        connect.tap()
        XCTAssertTrue(app.buttons["files-source-folder"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["files-source-files"].exists)
        XCTAssertFalse(app.buttons["files-source-save"].exists, "An empty selection cannot create a source.")
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
