import CineVaultCore
import XCTest
@testable import CineVault

final class SubtitleSMBIntegrationTests: XCTestCase {
    func testSiblingSRTWebVTTInvalidAndOversizedFilesFromSyntheticNAS() async throws {
        let config = SourceConfig(id: UUID(), host: "127.0.0.1", port: 1445, share: "MEDIAPLAYBACK", rootPath: "TV Shows", username: "cinevault", password: "fixture-only")
        let path = "TV Shows/Fixture Show/Season 01/Fixture Show.S01E01.mp4"
        let files = try await LocalSubtitleService.discover(config: config, videoPath: path)
        XCTAssertEqual(Set(files.compactMap(\.language)), ["en", "es", "fr", "de"])
        let english = try XCTUnwrap(files.first { $0.language == "en" })
        let document = try await LocalSubtitleService.read(english, config: config)
        XCTAssertEqual(document.text(at: 1), "Episode 1: English subtitle.")
        XCTAssertEqual(document.text(at: 8), "The next caption follows a seek.")
        XCTAssertEqual(document.text(at: 2), "Episode 1: English subtitle.")
        let spanish = try XCTUnwrap(files.first { $0.language == "es" })
        let spanishDocument = try await LocalSubtitleService.read(spanish, config: config)
        XCTAssertTrue(spanishDocument.text(at: 1).contains("Episodio 1"))
        for language in ["fr", "de"] {
            do {
                let file = try XCTUnwrap(files.first { $0.language == language })
                _ = try await LocalSubtitleService.read(file, config: config)
                XCTFail("Invalid or oversized sidecars must not load")
            } catch { XCTAssertTrue(error is SubtitleError) }
        }
        await SMBService.shared.reset(config)
    }
}
