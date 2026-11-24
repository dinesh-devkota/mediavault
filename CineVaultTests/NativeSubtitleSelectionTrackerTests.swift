import XCTest
@testable import CineVault

final class NativeSubtitleSelectionTrackerTests: XCTestCase {
    func testDelayedNativeOffCannotErasePendingSidecarSelection() {
        var tracker = NativeSubtitleSelectionTracker(current: 1)
        tracker.request(nil, current: 1)
        XCTAssertFalse(tracker.changed(to: 1), "The old native state can remain immediately after select(nil)")
        XCTAssertFalse(tracker.changed(to: nil), "Its delayed Off notification belongs to the sidecar request")
        XCTAssertFalse(tracker.changed(to: nil), "Duplicate notifications are harmless")
        XCTAssertTrue(tracker.changed(to: 2), "A subsequent explicit native track replaces the sidecar")
    }

    func testAutomaticPreferredNativeTargetCanArriveLater() {
        var tracker = NativeSubtitleSelectionTracker(current: nil)
        tracker.request(2, current: nil)
        XCTAssertFalse(tracker.changed(to: nil))
        XCTAssertFalse(tracker.changed(to: 2), "Automatic's resolved preferred track must not be mistaken for a manual override")
        XCTAssertTrue(tracker.changed(to: nil), "An explicit native Off after completion is remembered")
    }

    func testNoOpAndChangedNativeChoiceNeverLeaveSuppressionStuck() {
        var tracker = NativeSubtitleSelectionTracker(current: nil)
        tracker.request(nil, current: nil)
        XCTAssertFalse(tracker.changed(to: nil))
        XCTAssertTrue(tracker.changed(to: 1))
        tracker.request(2, current: 1)
        XCTAssertFalse(tracker.changed(to: 1))
        XCTAssertTrue(tracker.changed(to: 3), "A distinct native UI choice supersedes a pending target")
        XCTAssertTrue(tracker.changed(to: nil))
    }
}
