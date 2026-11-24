import Foundation
import XCTest
@testable import CineVaultCore

final class SubtitleTests: XCTestCase {
    func testSRTBOMCRLFMarkupOverlapsAndBidirectionalSeek() throws {
        let data = Data("\u{FEFF}1\r\n00:00:01,000 --> 00:00:03,000\r\n<i>Hello</i> &amp; goodbye\r\nSecond line\r\n\r\n2\r\n00:00:02,500 --> 00:00:04,000\r\n{\\an8}Overlap\r\n".utf8)
        let document = try SubtitleDocument.parse(data)
        XCTAssertEqual(document.text(at: 0.9), "")
        XCTAssertEqual(document.text(at: 1), "Hello & goodbye\nSecond line")
        XCTAssertEqual(document.text(at: 2.5), "Hello & goodbye\nSecond line\nOverlap")
        XCTAssertEqual(document.text(at: 3), "Overlap")
        XCTAssertEqual(document.text(at: 4), "")
        XCTAssertEqual(document.text(at: 1.5), "Hello & goodbye\nSecond line")
        XCTAssertEqual(document.text(at: .nan), "")
    }

    func testWebVTTIdentifiersSettingsAndNonCueBlocks() throws {
        let input = """
        WEBVTT

        STYLE
        ::cue { color: lime; }

        NOTE private comment
        00:00.000 --> 01:00.000
        Not a caption

        REGION
        id:bottom

        hello
        00:01.000 --> 00:03.500 align:start position:10%
        <v Ann><c.green>Hello</c></v>

        00:04.000 --> 00:05.000
        Next
        """
        let document = try SubtitleDocument.parse(Data(input.utf8))
        XCTAssertEqual(document.cues.count, 2)
        XCTAssertEqual(document.text(at: 1.5), "Hello")
        XCTAssertEqual(document.text(at: 3.5), "")
    }

    func testUTF16MalformedAndOversizedInput() throws {
        let valid = "1\n00:00:00,000 --> 00:00:02,000\n你好"
        XCTAssertEqual(try SubtitleDocument.parse(XCTUnwrap(valid.data(using: .utf16))).text(at: 1), "你好")
        for input in ["garbage", "1\n00:01:02,000 --> 00:01:01,000\nBackwards", "1\n00:99:00,000 --> 01:40:00,000\nInvalid", "1\n00:00:NaN --> 00:00:04,000\nNaN"] {
            XCTAssertThrowsError(try SubtitleDocument.parse(Data(input.utf8)))
        }
        XCTAssertThrowsError(try SubtitleDocument.parse(Data([0xFF, 0x01, 0xFE])))
        XCTAssertThrowsError(try SubtitleDocument.parse(Data(repeating: 65, count: SubtitleDocument.maximumBytes + 1))) {
            XCTAssertEqual($0 as? SubtitleError, .tooLarge)
        }
    }

    func testExactMatchingLanguageVariantsAndBoundaries() throws {
        let video = "Media/Show/Show.S01E01.mp4"
        let match = try XCTUnwrap(SubtitleFile.match(name: "SHOW.S01E01.pt-BR.forced.sdh.SRT", videoPath: video, rootPath: "media"))
        XCTAssertEqual(match.language, "pt-br")
        XCTAssertTrue(match.forced)
        XCTAssertTrue(match.hearingImpaired)
        XCTAssertEqual(match.path, "Media/Show/SHOW.S01E01.pt-BR.forced.sdh.SRT")
        XCTAssertNotNil(SubtitleFile.match(name: "Show.S01E01.vtt", videoPath: video, rootPath: "Media"))
        for name in ["Show.S01E010.en.srt", "Show.S01E01.release.srt", "Show.S01E01.en.es.srt", "Show.S01E01.en.sdh.sdh.srt", "Show.S01E01.en.ass", "../Show.S01E01.srt", "Show.S01E01..srt"] {
            XCTAssertNil(SubtitleFile.match(name: name, videoPath: video, rootPath: "Media"), name)
        }
    }

    func testSourceRootAndExclusionsAreEnforced() {
        for path in ["Media/../Other/Movie.mp4", "Other/Movie.mp4", "Media2/Movie.mp4", "//NAS/Media/Movie.mp4", "smb://NAS/Media/Movie.mp4", "C:\\Media\\Movie.mp4", "Media/./Movie.mp4", "Media/Movie\u{0000}.mp4"] {
            XCTAssertNil(SubtitleFile.match(name: "Movie.en.srt", videoPath: path, rootPath: "Media"), path)
        }
        XCTAssertNil(SubtitleFile.match(name: "Movie.en.srt", videoPath: "Media/Film/Movie.mp4", rootPath: "Media", ignoredFolders: ["film"]))
        XCTAssertNil(SubtitleFile.match(name: "Movie.en.srt", videoPath: "Media/Film/Movie.mp4", rootPath: "Media", ignoredFiles: ["Film/Movie.EN.SRT"]))
        XCTAssertNil(SubtitleFile.match(name: "Movie.en.srt", videoPath: "Media/Film/Movie.mp4", rootPath: "Media", ignoredFiles: ["Film/Movie.mp4"]))
        XCTAssertEqual(SubtitleFile.directory(for: "Movie.mp4", rootPath: ""), "")
        XCTAssertEqual(SubtitleFile.directory(for: "Media\\Movie.mp4", rootPath: "Media"), "Media")
    }
}
