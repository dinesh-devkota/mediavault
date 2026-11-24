import CineVaultCore
import XCTest
@testable import CineVault

final class LocalSubtitleServiceTests: XCTestCase {
    private var config: SourceConfig {
        SourceConfig(id: UUID(), host: "fixture.invalid", share: "Media", rootPath: "TV", username: "", password: "", ignoredFiles: ["Show/Show.S01E01.fr.srt"])
    }
    private let path = "TV/Show/Show.S01E01.mp4"

    func testDiscoveryListsOnlySiblingFolderAndFiltersIgnoredDirectoriesAndOtherEpisodes() async throws {
        var directories: [String] = []
        let results = try await LocalSubtitleService.discover(config: config, videoPath: path) { _, directory in
            directories.append(directory)
            return [NASDirectoryEntry(name: "Show.S01E01.en.srt", isDirectory: false),
                    NASDirectoryEntry(name: "Show.S01E01.fr.srt", isDirectory: false),
                    NASDirectoryEntry(name: "Show.S01E01.es.vtt", isDirectory: false),
                    NASDirectoryEntry(name: "Show.S01E010.en.srt", isDirectory: false),
                    NASDirectoryEntry(name: "Show.S01E01.srt", isDirectory: true),
                    NASDirectoryEntry(name: "../Show.S01E01.srt", isDirectory: false)]
        }
        XCTAssertEqual(directories, ["TV/Show"])
        XCTAssertEqual(results.map(\.language), ["en", "es"])
    }

    func testUnsafeSourcePathNeverLists() async {
        do {
            _ = try await LocalSubtitleService.discover(config: config, videoPath: "TV/../Other/Show.S01E01.mp4") { _, _ in
                XCTFail("An unsafe path cannot reach the NAS"); return []
            }
            XCTFail("Unsafe paths must fail")
        } catch { XCTAssertEqual(error as? SMBError, .sourceChanged) }
    }

    func testOversizedFileNeverReadsAndTruncationFails() async throws {
        let file = try XCTUnwrap(SubtitleFile.match(name: "Show.S01E01.en.srt", videoPath: path, rootPath: "TV"))
        do {
            _ = try await LocalSubtitleService.read(file, config: config, size: { _, _ in Int64(SubtitleDocument.maximumBytes + 1) }, read: { _, _, _ in
                XCTFail("An oversized file must be rejected before reading"); return Data()
            })
            XCTFail("Expected size rejection")
        } catch { XCTAssertEqual(error as? SubtitleError, .tooLarge) }
        do {
            _ = try await LocalSubtitleService.read(file, config: config, size: { _, _ in 10 }, read: { _, _, count in
                XCTAssertEqual(count, 10); return Data("short".utf8)
            })
            XCTFail("Expected truncated read rejection")
        } catch { XCTAssertEqual(error as? SMBError, .unexpectedEndOfFile) }
    }

    func testDiscoveryBoundsCandidatesAndPrefersLanguage() async throws {
        let results = try await LocalSubtitleService.discover(config: config, videoPath: path, preferredLanguage: "zu") { _, _ in
            ["af", "ar", "de", "en", "es", "fr", "it", "ja", "ko", "nl", "pt", "zu"].map {
                NASDirectoryEntry(name: "Show.S01E01.\($0).srt", isDirectory: false)
            }
        }
        XCTAssertEqual(results.count, 8)
        XCTAssertEqual(results.first?.language, "zu")
    }
}
