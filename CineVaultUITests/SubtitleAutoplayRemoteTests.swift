import XCTest

final class SubtitleAutoplayRemoteTests: XCTestCase {
    @MainActor
    func testRemoteSelectsLocalSubtitlesThenOffAndBackCancelsCountdown() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-playback"]
        app.launch()
        defer { capture("Subtitle and countdown test final state", app: app) }
        let remote = XCUIRemote.shared
        let open = app.buttons["fixture-subtitles"]
        XCTAssertTrue(open.waitForExistence(timeout: 40), app.debugDescription)
        focus(open, in: app)
        remote.press(.select)
        let english = app.buttons["subtitle-TV Shows/Fixture Show/Season 01/Fixture Show.S01E01.en.srt"]
        XCTAssertTrue(english.waitForExistence(timeout: 30), app.debugDescription)
        focus(english, in: app)
        remote.press(.select)
        assertSelected(english)
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
        assertSelected(off)
        let automatic = app.buttons["subtitle-system"]
        focus(automatic, in: app)
        remote.press(.select)
        assertSelected(english)
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
        defer { capture("Play now test final state", app: app) }
        let finish = app.buttons["fixture-finish-episode"]
        XCTAssertTrue(finish.waitForExistence(timeout: 40), app.debugDescription)
        focus(finish, in: app)
        XCUIRemote.shared.press(.select)
        let play = app.buttons["autoplay-play-now"]
        XCTAssertTrue(play.waitForExistence(timeout: 15), app.debugDescription)
        focus(play, in: app)
        capture("Natural end countdown with Play now focused", app: app)
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
        defer { capture("Native transport test final state", app: app) }
        let remote = XCUIRemote.shared
        let subtitles = app.cells["Subtitles"].firstMatch
        // This fixture uses the real native transport, without test-only focusable buttons.
        XCTAssertTrue(subtitles.waitForExistence(timeout: 40), app.debugDescription)
        // AVKit keeps hidden transport items in its accessibility tree. Its
        // fullscreen surface uses Up to reveal/focus controls regardless of their
        // on-screen coordinates; a geometric Down move can hide them again.
        for attempt in 0..<8 {
            if subtitles.hasFocus { break }
            let focusedCell = app.cells.matching(NSPredicate(format: "hasFocus == YES")).firstMatch
            if focusedCell.exists {
                remote.press(focusedCell.frame.midX > subtitles.frame.midX ? .left : .right)
            } else {
                remote.press(.up)
            }
            if attempt == 1 { capture("Native transport after revealing controls", app: app) }
        }
        capture("Native transport focus result", app: app)
        XCTAssertTrue(subtitles.hasFocus, app.debugDescription)
        XCTAssertTrue(subtitles.isHittable, app.debugDescription)
        capture("Production transport subtitle action", app: app)
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
    private func assertSelected(_ element: XCUIElement) {
        // tvOS can append its checkmark's accessibility state to the button's explicit value.
        // Wait for action delivery and the accessibility value to settle. Capture
        // any NAS load error instead of checking the pre-action snapshot immediately.
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", "Selected"), object: element)
        let result = XCTWaiter.wait(for: [selected], timeout: 15)
        if result != .completed { capture("Subtitle selection did not complete", app: XCUIApplication()) }
        XCTAssertEqual(result, .completed, XCUIApplication().debugDescription)
    }

    @MainActor
    private func focus(_ target: XCUIElement, in app: XCUIApplication) {
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == YES")).firstMatch
        func targetIsFocused() -> Bool {
            if target.hasFocus { return true }
            // List rows own focus on tvOS; the actionable Button remains their descendant.
            return !target.identifier.isEmpty && app.cells.containing(.button, identifier: target.identifier)
                .matching(NSPredicate(format: "hasFocus == YES")).firstMatch.exists
        }
        for _ in 0..<20 {
            if targetIsFocused() { return }
            if focused.exists, abs(focused.frame.midY - target.frame.midY) < 30 {
                XCUIRemote.shared.press(focused.frame.midX < target.frame.midX ? .right : .left)
            } else {
                XCUIRemote.shared.press(focused.exists && focused.frame.midY > target.frame.midY ? .up : .down)
            }
        }
        if !targetIsFocused() { capture("Remote focus did not reach \(target.identifier.isEmpty ? target.label : target.identifier)", app: app) }
        XCTAssertTrue(targetIsFocused(), app.debugDescription)
    }
}
