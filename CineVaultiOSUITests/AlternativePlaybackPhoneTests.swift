import XCTest

final class AlternativePlaybackPhoneTests: XCTestCase {
    @MainActor
    func testMKVTouchPlaybackSeekingSubtitlesAndAudioKeepSession() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-alternative-playback"]
        app.launch()
        defer { capture("MKV phone journey final state", app) }
        waitLabel(app.staticTexts["fixture-alternative-ready"], "Playback advanced", app, timeout: 45)
        let play = app.buttons["alternative-play-pause"]
        waitLabel(app.staticTexts["fixture-alternative-state"], "Playing", app)
        tapPlayingControl("alternative-play-pause", app)
        waitLabel(app.staticTexts["fixture-alternative-state"], "Paused", app)
        XCTAssertTrue(app.staticTexts["MKV playback controls"].exists,
                      "The dark playback overlay must include the current title.")
        // Inspect targets while paused; repeated accessibility snapshots can
        // legitimately outlast the five-second playing-controls timeout.
        for id in ["playback-close", "playback-subtitles", "alternative-rewind", "alternative-play-pause", "alternative-forward"] {
            let button = app.buttons[id]
            XCTAssertTrue(button.isHittable, id + " must have an accessible touch target")
            XCTAssertGreaterThanOrEqual(button.frame.width, 44, id)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, id)
        }
        let first = seconds(app)
        app.buttons["alternative-forward"].tap()
        wait(app, "Forward seeks the real decoder") { self.seconds(app) >= first + 8 }
        let slider = app.sliders["alternative-seek"]
        XCTAssertTrue(slider.isHittable)
        slider.adjust(toNormalizedSliderPosition: 0.35)
        wait(app, "Touch scrubber seeks to the chosen part of the movie") { (15...28).contains(self.seconds(app)) }

        app.buttons["playback-subtitles"].tap()
        let local = app.buttons["subtitle-Controls.en.srt"]
        XCTAssertTrue(local.waitForExistence(timeout: 15), app.debugDescription)
        local.tap()
        waitSelected(local, app)
        app.buttons["subtitles-done"].tap()
        wait(app, "Subtitle sheet dismisses") { !app.buttons["subtitles-done"].exists }
        waitLabel(app.staticTexts["fixture-alternative-state"], "Paused", app)
        XCTAssertTrue(app.staticTexts["local-subtitle-caption"].waitForExistence(timeout: 10), app.debugDescription)
        capture("MKV local subtitle with phone transport controls", app)

        let beforeAudio = seconds(app)
        app.buttons["playback-audio"].tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "playback-audio-track-"))
        wait(app, "Both audio tracks appear") { rows.count == 2 }
        let alternateID = rows.element(boundBy: 1).identifier
        rows.element(boundBy: 1).tap()
        wait(app, "Audio selection returns to playback") { !app.buttons["playback-audio-done"].exists }
        waitLabel(app.staticTexts["fixture-alternative-state"], "Paused", app)
        XCTAssertGreaterThanOrEqual(seconds(app), beforeAudio - 1, "Opening options must not recreate or rewind the player")
        app.buttons["playback-audio"].tap()
        waitSelected(app.buttons[alternateID], app)
        capture("MKV phone audio selection persists", app)
        app.buttons["playback-audio-done"].tap()
        wait(app, "Audio Done returns to transport") { !app.buttons["playback-audio-done"].exists }

        let resumedFrom = seconds(app)
        play.tap()
        waitLabel(app.staticTexts["fixture-alternative-state"], "Playing", app)
        wait(app, "Video continues after both sheets close") { self.seconds(app) > resumedFrom + 0.5 }
        tapPlayingControl("playback-close", app)
        XCTAssertTrue(app.staticTexts["fixture-alternative-closed"].waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor private func tapPlayingControl(_ identifier: String, _ app: XCUIApplication) {
        let control = app.buttons[identifier]
        // Refresh the real five-second visibility window and act immediately.
        // Separate exists/enabled/hittable queries can consume that whole window
        // on a busy simulator; tap performs its own target and hit-point checks.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        control.tap()
    }
    @MainActor private func seconds(_ app: XCUIApplication) -> Double {
        let item = app.staticTexts["fixture-alternative-seconds"]
        return item.exists ? Double(item.label) ?? -1 : -1
    }
    @MainActor private func waitLabel(_ item: XCUIElement, _ label: String, _ app: XCUIApplication, timeout: Double = 10) {
        wait(app, "Expected " + label, timeout: timeout) { item.exists && item.label == label }
    }
    @MainActor private func waitSelected(_ item: XCUIElement, _ app: XCUIApplication) {
        wait(app, "The chosen track is selected") { item.exists && (item.value as? String)?.hasPrefix("Selected") == true }
    }
    @MainActor private func wait(_ app: XCUIApplication, _ message: String, timeout: Double = 10, condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, message + "\n" + app.debugDescription)
    }
    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let tree = XCTAttachment(string: app.debugDescription); tree.name = name + " accessibility"; tree.lifetime = .keepAlways; add(tree)
    }
}
