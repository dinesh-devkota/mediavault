import XCTest
@testable import CineVault

@MainActor
final class SubtitleReleaseSelectionTests: XCTestCase {
    private func result(_ release: String, id: String = "one", aliases: [String] = []) -> SubDLSubtitle {
        SubDLSubtitle(id: id, language: "en", releaseName: release, format: "srt", hearingImpaired: false,
                      downloadURL: URL(string: "https://dl.subdl.com/subtitle/\(id).srt")!, fps: nil, releaseNames: aliases)
    }
    func testOnlyOneExactReleaseMayBeAutomaticallySelected() {
        let exact = result("Show.S01E02.1080p.WEB-GROUP.srt")
        let wrong = result("Show.S01E02.720p.BluRay-OTHER", id: "other")
        let path = "TV/Show.S01E02.1080P.WEB-GROUP.mp4"
        XCTAssertEqual(PlaybackSubtitles.automaticMatch([wrong, exact], videoPath: path)?.id, exact.id)
        XCTAssertNil(PlaybackSubtitles.automaticMatch([wrong], videoPath: path))
        XCTAssertNil(PlaybackSubtitles.automaticMatch([exact, result(exact.releaseName, id: "duplicate")], videoPath: path))
        XCTAssertNil(PlaybackSubtitles.automaticMatch([exact], videoPath: "TV/Show.S01E03.1080p.WEB-GROUP.mp4"))
        XCTAssertEqual(PlaybackSubtitles.automaticMatch([result("Other name", aliases: [exact.releaseName])], videoPath: path)?.id, "one")
    }

    func testEmbeddedLanguageAliasesMatchWithoutMixingExplicitRegions() {
        XCTAssertTrue(PlaybackSubtitles.sameLanguage("en-US", "en"))
        XCTAssertTrue(PlaybackSubtitles.sameLanguage("eng", "en"))
        XCTAssertTrue(PlaybackSubtitles.sameLanguage("fre", "fr"))
        XCTAssertTrue(PlaybackSubtitles.sameLanguage("pt_BR", "pt-br"))
        XCTAssertFalse(PlaybackSubtitles.sameLanguage("pt-PT", "pt-br"))
        XCTAssertFalse(PlaybackSubtitles.sameLanguage("es", "en"))
    }
}
