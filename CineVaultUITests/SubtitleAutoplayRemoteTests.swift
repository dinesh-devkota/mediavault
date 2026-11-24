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
        remote.press(.menu)
        let caption = app.staticTexts["local-subtitle-caption"]
        XCTAssertTrue(caption.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(caption.label, "Episode 1: English subtitle.")
        capture("Local subtitles rendered over NAS video", app: app)
        focus(open, in: app)
        remote.press(.select)
        let off = app.buttons["subtitles-off"]
        focus(off, in: app)
        remote.press(.select)
        XCTAssertEqual(off.value as? String, "Selected")
        let automatic = app.buttons["subtitle-system"]
        focus(automatic, in: app)
        remote.press(.select)
        XCTAssertEqual(english.value as? String, "Selected", "Automatic must restore the preferred local track in this player")
        remote.press(.menu)
        XCTAssertTrue(caption.waitForExistence(timeout: 15), app.debugDescription)
        capture("Automatic restored captions after Off", app: app)
        focus(open, in: app)
        remote.press(.select)
        focus(off, in: app)
        remote.press(.select)
        remote.press(.menu)
        XCTAssertFalse(caption.exists)
        let finish = app.buttons["fixture-finish-episode"]
        XCTAssertTrue(finish.waitForExistence(timeout: 10))
        focus(finish, in: app)
        remote.press(.select)
        let countdown = app.staticTexts["next-episode-countdown"]
        XCTAssertTrue(countdown.waitForExistence(timeout: 15), app.debugDescription)
        capture("Natural end next episode countdown", app: app)
        remote.press(.menu)
        XCTAssertTrue(finish.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(countdown.exists)
        XCTAssertTrue(app.staticTexts["fixture-playing-episode"].label.contains("S01E01"))
        capture("Back cancelled next episode countdown", app: app)
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
        capture("Play now opened episode two", app: app)
    }

    @MainActor
    func testProductionTransportOpensSubtitleOptions() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-playback", "--ui-preview-production-controls"]
        app.launch()
        let remote = XCUIRemote.shared
        let subtitles = app.buttons["Subtitles"]
        // This fixture uses the real native transport, without test-only focusable buttons.
        for _ in 0..<6 {
            if subtitles.exists { break }
            remote.press(.select)
            if subtitles.waitForExistence(timeout: 5) { break }
            remote.press(.down)
        }
        XCTAssertTrue(subtitles.waitForExistence(timeout: 10), app.debugDescription)
        capture("Production transport subtitle action", app: app)
        focus(subtitles, in: app)
        remote.press(.select)
        XCTAssertTrue(app.buttons["subtitles-off"].waitForExistence(timeout: 10), app.debugDescription)
        capture("Production subtitle selection sheet", app: app)
    }

    @MainActor
    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
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
