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
        address.typeText("https://127.0.0.1:15443/dav/")

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
        XCTAssertTrue(app.staticTexts["Fixture media"].waitForExistence(timeout: 25), "Expected the authenticated source to be saved.")

        dismissPasswordPrompt(in: app)

        let scan = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "1 item · Scanned ")).firstMatch
        XCTAssertTrue(scan.waitForExistence(timeout: 25), app.debugDescription)

        let library = app.tabBars.buttons["Library"]
        library.tap()
        dismissPasswordPrompt(in: app)
        if !library.isSelected { library.tap() }
        XCTAssertTrue(library.isSelected, app.debugDescription)
        let poster = app.buttons["Film"]
        for _ in 0..<3 where !poster.isHittable { app.swipeUp() }
        XCTAssertTrue(poster.isHittable, app.debugDescription)
        poster.tap()
        XCTAssertTrue(app.staticTexts["Film"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["Play"].exists, app.debugDescription)
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
        XCTAssertTrue(app.staticTexts["plex-link-code"].waitForExistence(timeout: 5), app.debugDescription)

        let server = app.buttons["Fixture Plex"]
        XCTAssertTrue(server.waitForExistence(timeout: 15), app.debugDescription)
        server.tap()
        let section = app.buttons["Fixture Movies"]
        XCTAssertTrue(section.waitForExistence(timeout: 15), app.debugDescription)
        section.tap()

        let scan = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "2 items · Scanned ")).firstMatch
        XCTAssertTrue(scan.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Fixture Movies"].exists)
        let library = app.tabBars.buttons["Library"]
        library.tap()
        let poster = app.buttons["Fixture Movie"]
        for _ in 0..<3 where !poster.isHittable { app.swipeUp() }
        XCTAssertTrue(poster.isHittable, app.debugDescription)
        poster.tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor
    private func dismissPasswordPrompt(in app: XCUIApplication) {
        let prompt = app.sheets["Save Password?"]
        if prompt.waitForExistence(timeout: 4) {
            prompt.buttons["Not Now"].tap()
        }
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
