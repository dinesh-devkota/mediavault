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
        tapPlayingControl("alternative-play-pause", app, until: NSPredicate(format: "label == %@", "Paused"),
                          on: app.staticTexts["fixture-alternative-state"])
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
        wait(app, "Forward seeks the real decoder") {
            guard let seek = self.seekEvidence(app) else { return false }
            return seek.sequence == 1 && seek.submitted && seek.decoder >= first + 8 && abs(seek.decoder - seek.target) <= 2
        }
        verifyTouchScrubber(app)

        app.buttons["playback-subtitles"].tap()
        let local = app.buttons["subtitle-Controls.en.srt"]
        XCTAssertTrue(local.waitForExistence(timeout: 15), app.debugDescription)
        local.tap()
        waitSelected(local, app)
        app.buttons["subtitles-done"].tap()
        wait(app, "Subtitle sheet dismisses") { !app.buttons["subtitles-done"].exists }
        waitLabel(app.staticTexts["fixture-alternative-state"], "Paused", app)
        XCTAssertTrue(app.staticTexts["local-subtitle-caption"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertLessThanOrEqual(app.staticTexts["local-subtitle-caption"].frame.maxY,
                                 app.staticTexts["MKV playback controls"].frame.minY,
                                 "Captions must remain above the visible transport panel.")
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
        tapPlayingControl("playback-close", app, until: NSPredicate(format: "exists == true"),
                          on: app.staticTexts["fixture-alternative-closed"])
    }

    @MainActor private func tapPlayingControl(_ identifier: String, _ app: XCUIApplication,
                                               until outcome: NSPredicate, on probe: XCUIElement) {
        let control = app.buttons[identifier]
        let ready = NSPredicate(format: "hittable == true AND enabled == true")
        for timeout in [3.0, 10.0] {
            if outcome.evaluate(with: probe) { return }
            // Reveal controls via the same video-area touch a viewer uses. On
            // a busy simulator the overlay can transition while routing a tap.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
            let actionable = XCTNSPredicateExpectation(predicate: ready, object: control)
            guard XCTWaiter.wait(for: [actionable], timeout: 2) == .completed else { continue }
            if outcome.evaluate(with: probe) { return }
            control.tap()
            let completed = XCTNSPredicateExpectation(predicate: outcome, object: probe)
            if XCTWaiter.wait(for: [completed], timeout: timeout) == .completed { return }
        }
        XCTAssertTrue(outcome.evaluate(with: probe), "The \(identifier) touch did not change playback.\n" + app.debugDescription)
    }
    private struct SeekEvidence: CustomStringConvertible {
        let sequence: Int
        let target: Double
        let submitted: Bool
        let decoder: Double

        var description: String { "sequence=\(sequence), target=\(target), submitted=\(submitted), decoder=\(decoder)" }
    }

    @MainActor private func seekEvidence(_ app: XCUIApplication) -> SeekEvidence? {
        let probe = app.staticTexts["fixture-alternative-seek-evidence"]
        guard probe.exists else { return nil }
        let fields = probe.label.split(separator: "|")
        guard fields.count == 4, let sequence = Int(fields[0]), let target = Double(fields[1]),
              let submitted = Bool(String(fields[2])), let decoder = Double(fields[3]) else { return nil }
        return SeekEvidence(sequence: sequence, target: target, submitted: submitted, decoder: decoder)
    }

    @MainActor private func verifyTouchScrubber(_ app: XCUIApplication) {
        let slider = app.sliders["alternative-seek"]
        XCTAssertTrue(slider.isHittable)
        guard let before = seekEvidence(app) else {
            XCTFail("Expected the native seek evidence before touching the slider.")
            return
        }
        slider.adjust(toNormalizedSliderPosition: 0.35)
        let targetWindow = 15.0...28.0
        var observed: SeekEvidence?
        let landed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let seek = self.seekEvidence(app) else { return false }
            observed = seek
            return seek.sequence == before.sequence + 1 && seek.submitted && targetWindow.contains(seek.target)
                && targetWindow.contains(seek.decoder) && abs(seek.decoder - seek.target) <= 2
        }, object: nil)
        let result = XCTWaiter.wait(for: [landed], timeout: 10)
        let after = seekEvidence(app) ?? observed
        let evidence = "Normalized slider request: 0.35\nBefore: \(before)\nAfter: \(after?.description ?? "unavailable")"
        let attachment = XCTAttachment(string: evidence)
        attachment.name = "MKV slider request and native decoder clock"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(result, .completed, "Touch scrubber must submit one target in the expected part of the movie and land on the native clock.\n" + evidence)
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
