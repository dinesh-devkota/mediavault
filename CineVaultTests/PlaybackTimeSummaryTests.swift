import XCTest
@testable import CineVault

final class PlaybackTimeSummaryTests: XCTestCase {
    func testUsesActualFileDurationBeforeMetadata() {
        XCTAssertEqual(PlaybackTimeSummary.remaining(duration: 7_200, runtimeMinutes: 90, position: 1_800), "About 1h 30m left")
        XCTAssertEqual(PlaybackTimeSummary.remaining(duration: 3_660, runtimeMinutes: nil, position: 60), "About 1h left")
    }

    func testFallsBackToMetadataAndRoundsUp() {
        XCTAssertEqual(PlaybackTimeSummary.remaining(duration: 0, runtimeMinutes: 90, position: 3_600), "About 30 min left")
        XCTAssertEqual(PlaybackTimeSummary.remaining(duration: 122, runtimeMinutes: nil, position: 61), "About 2 min left")
        XCTAssertEqual(PlaybackTimeSummary.remaining(duration: 120, runtimeMinutes: nil, position: 61), "Less than a minute left")
    }

    func testUnknownInvalidOrCompletedTimeDoesNotInventAnEstimate() {
        XCTAssertNil(PlaybackTimeSummary.remaining(duration: 0, runtimeMinutes: nil, position: 40))
        XCTAssertNil(PlaybackTimeSummary.remaining(duration: 120, runtimeMinutes: 2, position: 120))
        XCTAssertNil(PlaybackTimeSummary.remaining(duration: 120, runtimeMinutes: 2, position: 150))
        XCTAssertNil(PlaybackTimeSummary.remaining(duration: 120, runtimeMinutes: nil, position: -1))
        XCTAssertNil(PlaybackTimeSummary.remaining(duration: 120, runtimeMinutes: nil, position: .nan))
        XCTAssertNil(PlaybackTimeSummary.remaining(duration: .infinity, runtimeMinutes: nil, position: 40))
        XCTAssertNil(PlaybackTimeSummary.remaining(duration: .greatestFiniteMagnitude, runtimeMinutes: nil, position: 40))
    }
}
