import XCTest

final class AlternativePlaybackRemoteTests: XCTestCase {
    @MainActor
    func testMKVRemotePlaybackSeekingSubtitlesAndAudioKeepSession() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-alternative-playback"]
        app.launch()
        defer { capture("MKV remote journey final state", app) }
        wait(app, "The real MKV decoder advances", timeout: 45) { app.staticTexts["fixture-alternative-ready"].label == "Playback advanced" }
        let remote = XCUIRemote.shared
        remote.press(.playPause)
        wait(app, "Remote pauses playback") { app.staticTexts["fixture-alternative-state"].label == "Paused" }
        let first = seconds(app)
        select(app.buttons["alternative-forward"], app)
        wait(app, "Remote skips forward in MKV") { self.seconds(app) >= first + 8 }
        let forward = seconds(app)
        select(app.buttons["alternative-rewind"], app)
        wait(app, "Remote skips backwards in MKV") { self.seconds(app) < forward - 5 }
        select(app.buttons["alternative-forward"], app)
        wait(app, "Move to a subtitle cue") { self.seconds(app) > 8 }
        select(app.buttons["playback-subtitles"], app)
        let local = app.buttons["subtitle-Controls.en.srt"]
        XCTAssertTrue(local.waitForExistence(timeout: 15), app.debugDescription)
        select(local, app)
        waitSelected(local, app)
        remote.press(.menu)
        wait(app, "Back dismisses subtitles without closing playback") { !app.buttons["subtitles-done"].exists && app.buttons["alternative-play-pause"].exists }
        XCTAssertTrue(app.staticTexts["local-subtitle-caption"].waitForExistence(timeout: 10), app.debugDescription)
        capture("MKV remote controls with local captions", app)

        let beforeAudio = seconds(app)
        select(app.buttons["playback-audio"], app)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "playback-audio-track-"))
        wait(app, "Both audio tracks appear") { rows.count == 2 }
        let alternateID = rows.element(boundBy: 1).identifier
        select(rows.element(boundBy: 1), app)
        wait(app, "Selecting audio returns to playback") { !app.buttons["playback-audio-done"].exists }
        XCTAssertGreaterThanOrEqual(seconds(app), beforeAudio - 1)
        select(app.buttons["playback-audio"], app)
        waitSelected(app.buttons[alternateID], app)
        capture("MKV remote audio selection persists", app)
        remote.press(.menu)
        wait(app, "Back dismisses audio without stopping the session") { !app.buttons["playback-audio-done"].exists && app.buttons["alternative-play-pause"].exists }
        let resume = seconds(app)
        remote.press(.playPause)
        wait(app, "Remote resumes the same MKV session") { app.staticTexts["fixture-alternative-state"].label == "Playing" && self.seconds(app) > resume + 0.5 }
        capture("MKV resumes after subtitle and audio sheets", app)
        remote.press(.menu)
        XCTAssertTrue(app.staticTexts["fixture-alternative-closed"].waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor private func select(_ target: XCUIElement, _ app: XCUIApplication) {
        XCTAssertTrue(target.waitForExistence(timeout: 10), app.debugDescription)
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == YES")).firstMatch
        func reached() -> Bool {
            target.hasFocus || app.cells.containing(.button, identifier: target.identifier)
                .matching(NSPredicate(format: "hasFocus == YES")).firstMatch.exists
        }
        for _ in 0..<22 {
            if reached() { break }
            if focused.exists, abs(focused.frame.midY - target.frame.midY) < 30 {
                XCUIRemote.shared.press(focused.frame.midX < target.frame.midX ? .right : .left)
            } else {
                XCUIRemote.shared.press(focused.exists && focused.frame.midY > target.frame.midY ? .up : .down)
            }
        }
        XCTAssertTrue(reached(), app.debugDescription)
        XCTAssertTrue(target.isHittable, app.debugDescription)
        XCUIRemote.shared.press(.select)
    }
    @MainActor private func seconds(_ app: XCUIApplication) -> Double {
        Double(app.staticTexts["fixture-alternative-seconds"].label) ?? -1
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
