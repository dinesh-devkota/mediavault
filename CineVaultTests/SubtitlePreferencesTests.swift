import XCTest
@testable import CineVault

final class SubtitlePreferencesTests: XCTestCase {
    private func withDefaults(_ check: (UserDefaults) -> Void) {
        let suite = "subtitle-preferences-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        check(defaults)
    }

    func testExplicitSettingsLanguageReplacesPreviousTrackAndOff() {
        for previous in ["local|en||", "embedded|en-US", "online|en", "off"] {
            withDefaults { defaults in
                defaults.set(previous, forKey: PlaybackSubtitles.preferenceKey)
                SubtitleSettings.selectLanguage("es", defaults: defaults)
                XCTAssertEqual(SubtitleSettings.requestedLanguage(defaults: defaults), "es")
                XCTAssertEqual(defaults.string(forKey: PlaybackSubtitles.preferenceKey), "preferred|es")
                XCTAssertFalse(defaults.bool(forKey: SubtitleSettings.enabledKey), "A language choice alone cannot consent to online lookup")
            }
        }
    }

    func testVerifiedConnectExplicitlyEnablesSelectedLanguageAfterOff() {
        withDefaults { defaults in
            defaults.set("off", forKey: PlaybackSubtitles.preferenceKey)
            defaults.set("pt-br", forKey: SubtitleSettings.languageKey)
            SubtitleSettings.connected(defaults: defaults)
            XCTAssertTrue(defaults.bool(forKey: SubtitleSettings.verifiedKey))
            XCTAssertTrue(defaults.bool(forKey: SubtitleSettings.enabledKey))
            XCTAssertEqual(defaults.string(forKey: PlaybackSubtitles.preferenceKey), "preferred|pt-br")
            XCTAssertEqual(SubtitleSettings.requestedLanguage(defaults: defaults), "pt-br")
        }
    }

    func testAutomaticRestoresConfiguredLanguageWhileManualTrackCarriesItsLanguage() {
        withDefaults { defaults in
            defaults.set("en", forKey: SubtitleSettings.languageKey)
            defaults.set("local|es|forced|", forKey: PlaybackSubtitles.preferenceKey)
            XCTAssertEqual(SubtitleSettings.requestedLanguage(defaults: defaults), "es")
            SubtitleSettings.selectAutomatic(defaults: defaults)
            XCTAssertEqual(SubtitleSettings.requestedLanguage(defaults: defaults), "en")
            XCTAssertEqual(defaults.string(forKey: PlaybackSubtitles.preferenceKey), "preferred|en")
        }
    }
}
