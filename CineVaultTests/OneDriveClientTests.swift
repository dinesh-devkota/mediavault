import XCTest
@testable import CineVault

final class OneDriveClientTests: XCTestCase {
    func testContentRangeMustMatchTheRequestedSliceAndKnownTotal() {
        XCTAssertTrue(OneDriveClient.matchesRange("bytes 5-9/10", offset: 5, end: 9))
        XCTAssertFalse(OneDriveClient.matchesRange("bytes 4-9/10", offset: 5, end: 9))
        XCTAssertFalse(OneDriveClient.matchesRange("bytes 5-9/9", offset: 5, end: 9))
        XCTAssertFalse(OneDriveClient.matchesRange("bytes 5-9/*", offset: 5, end: 9))
        XCTAssertFalse(OneDriveClient.matchesRange("bytes 5-9/10/11", offset: 5, end: 9))
    }
}
