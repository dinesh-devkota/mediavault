import Foundation
import XCTest
@testable import CineVault

final class GoogleDriveClientTests: XCTestCase {
    func testInvalidRangesAndIDsFailBeforeNetworkRequests() async throws {
        let client = GoogleDriveClient()
        let attempts: [(String, Int64, Int)] = [("../media", 0, 1), ("valid", -1, 1),
                                               ("valid", Int64.max, 1), ("valid", 0, 0)]
        for (id, offset, length) in attempts {
            do {
                _ = try await client.read(fileID: id, offset: offset, length: length, accessToken: "fixture")
                XCTFail("Expected range validation to fail")
            } catch GoogleDriveError.invalidRequest {
                continue
            }
        }
    }
}
