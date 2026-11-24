import XCTest

final class SubtitleAutoplayRemoteTests: XCTestCase {
    @MainActor
    func testRemoteSelectsLocalSubtitlesThenOffAndBackCancelsCountdown() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-playback"]
        app.launch()
        let remote = XCUIRemote.shared
        let open = app.buttons["fixture-subtitles"]
        XCTAssertTrue(open.waitForExistence(timeout: 40), app.debugDescription)
        focus(open, in: app)
        remote.press(.select)
        let english = app.buttons["subtitle-TV Shows/Fixture Show/Season 01/Fixture Show.S01E01.en.srt"]
        XCTAssertTrue(english.waitForExistence(timeout: 30), app.debugDescription)
        focus(english, in: app)
        remote.press(.select)
        XCTAssertEqual(english.value as? String, "Selected")
        let off = app.buttons["subtitles-off"]
        focus(off, in: app)
        remote.press(.select)
        XCTAssertEqual(off.value as? String, "Selected")
        remote.press(.menu)
        let finish = app.buttons["fixture-finish-episode"]
        XCTAssertTrue(finish.waitForExistence(timeout: 10))
        focus(finish, in: app)
        remote.press(.select)
        let countdown = app.staticTexts["next-episode-countdown"]
        XCTAssertTrue(countdown.waitForExistence(timeout: 15), app.debugDescription)
        remote.press(.menu)
        XCTAssertTrue(finish.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(countdown.exists)
        XCTAssertTrue(app.staticTexts["fixture-playing-episode"].label.contains("S01E01"))
    }

    @MainActor
    func testRemotePlayNowMovesToNextEpisode() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-playback"]
        app.launch()
        let finish = app.buttons["fixture-finish-episode"]
        XCTAssertTrue(finish.waitForExistence(timeout: 40), app.debugDescription)
        focus(finish, in: app)
        XCUIRemote.shared.press(.select)
        let play = app.buttons["autoplay-play-now"]
        XCTAssertTrue(play.waitForExistence(timeout: 15), app.debugDescription)
        focus(play, in: app)
        XCUIRemote.shared.press(.select)
        let second = app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "fixture-playing-episode", "S01E02")).firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 40), app.debugDescription)
    }

    @MainActor
    private func focus(_ target: XCUIElement, in app: XCUIApplication) {
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == YES")).firstMatch
        for _ in 0..<20 {
            if target.hasFocus { return }
            if focused.exists, abs(focused.frame.midY - target.frame.midY) < 30 {
                XCUIRemote.shared.press(focused.frame.midX < target.frame.midX ? .right : .left)
            } else {
                XCUIRemote.shared.press(focused.exists && focused.frame.midY > target.frame.midY ? .up : .down)
            }
        }
        XCTAssertTrue(target.hasFocus, app.debugDescription)
    }
}
