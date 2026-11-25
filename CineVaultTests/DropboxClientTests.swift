import Foundation
import XCTest
@testable import CineVault

final class DropboxClientTests: XCTestCase {
    func testAuthorizationUsesOfflinePKCEAndFreshState() throws {
        let callback = try XCTUnwrap(URL(string: "https://fixture.example/oauth/dropbox"))
        let client = try DropboxClient(appKey: "fixture-app", callback: callback)
        func query() throws -> [String: String] {
            let parts = try XCTUnwrap(URLComponents(url: client.beginAuthorization().url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(parts.host, "www.dropbox.com")
            return Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        }

        let first = try query()
        let second = try query()
        XCTAssertEqual(first["response_type"], "code")
        XCTAssertEqual(first["redirect_uri"], callback.absoluteString)
        XCTAssertEqual(first["token_access_type"], "offline")
        XCTAssertEqual(first["code_challenge_method"], "S256")
        XCTAssertEqual(first["code_challenge"]?.count, 43)
        XCTAssertEqual(first["state"]?.count, 43)
        XCTAssertNotEqual(first["state"], second["state"])
        XCTAssertNotEqual(first["code_challenge"], second["code_challenge"])
        XCTAssertNil(first["client_secret"])
    }
}
