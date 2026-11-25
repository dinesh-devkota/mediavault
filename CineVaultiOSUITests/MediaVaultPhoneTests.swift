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
        let name = app.textFields["Library name"]
        name.tap()
        name.typeText("Fixture media")
        address.tap()
        address.typeText("https://127.0.0.1:15443/dav/")

        app.switches["Guest access"].tap()
        let username = app.textFields["Username"]
        username.tap()
        username.typeText("cinevault")
        let password = app.secureTextFields["Password"]
        password.tap()
        password.typeText("fixture-only")

        let save = app.buttons["Save & scan"]
        for _ in 0..<5 where !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isHittable)
        save.tap()
        XCTAssertTrue(app.staticTexts["Fixture media"].waitForExistence(timeout: 25), "Expected the authenticated source to be saved.")

        app.tabBars.buttons["Library"].tap()
        let film = app.staticTexts["Film"].firstMatch
        XCTAssertTrue(film.waitForExistence(timeout: 25), "Expected the scan to import the fixture movie.")
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
