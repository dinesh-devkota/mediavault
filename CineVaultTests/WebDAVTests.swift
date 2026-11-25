@testable import CineVault
import Foundation
import XCTest

final class WebDAVTests: XCTestCase {
    private func entry(_ path: String, collection: Bool = true, status: Int = 200) -> String {
        """
        <d:response><d:href>\(path)</d:href><d:propstat>
            <d:prop><d:resourcetype>\(collection ? "<d:collection/>" : "")
            </d:resourcetype><d:getcontentlength>100</d:getcontentlength></d:prop>
            <d:status>HTTP/1.1 \(status) Result</d:status>
        </d:propstat></d:response>
        """
    }

    private func parse(_ contents: String) throws -> [WebDAVEntry] {
        let address = try WebDAVAddress("https://nas.example/media/")
        let xml = "<d:multistatus xmlns:d=\"DAV:\">\(contents)</d:multistatus>"
        return try WebDAVTransport.parseListing(Data(xml.utf8), address: address, requested: address.endpoint, directory: "")
    }

    func testListingPreservesCaseAndRejectsForeignAndNestedEntries() throws {
        let entries = try parse(entry("/media/") + entry("/media/Kids/") + entry("/media/kids/") +
            entry("https://foreign.example/media/Foreign/") + entry("/elsewhere/") + entry("/media/Kids/Grandchild/") +
            entry("/media/Denied/", status: 403))
        XCTAssertEqual(Set(entries.map(\.path)), ["Kids", "kids"])
    }

    func testFolderMustConfirmItsOwnSuccessfulCollection() throws {
        XCTAssertTrue(try parse(entry("/media/")).isEmpty)
        XCTAssertThrowsError(try parse(entry("/media/", status: 403)))
        XCTAssertThrowsError(try parse(entry("/media/", collection: false)))
        XCTAssertThrowsError(try parse(entry("/media/Child/")))
        XCTAssertThrowsError(try parse("<d:prop>\(entry("/media/"))</d:prop>"))
    }

    func testAddressRejectsRedirectTargetsAndUnsafePaths() throws {
        let address = try WebDAVAddress("https://nas.example:5006/media")
        XCTAssertEqual(try address.url(for: "Film #1.mkv").absoluteString, "https://nas.example:5006/media/Film%20%231.mkv")
        XCTAssertNil(address.relativePath(href: "/media/Kids%2Fprivate.mkv", requested: address.endpoint))
        XCTAssertNil(address.relativePath(href: "https://nas.example/media/Film.mkv", requested: address.endpoint))
        XCTAssertThrowsError(try address.url(for: "Kids/../private.mkv"))
        XCTAssertThrowsError(try WebDAVAddress("http://nas.example/media/"))
        XCTAssertThrowsError(try WebDAVAddress("https://name:password@nas.example/media/"))
    }

    func testByteRangeParsingChecksBounds() {
        XCTAssertEqual(WebDAVTransport.parseRange("bytes 5-9/10")?.total, 10)
        XCTAssertNil(WebDAVTransport.parseRange("bytes 5-10/10"))
        XCTAssertNil(WebDAVTransport.parseRange("bytes 5-9/*"))
        XCTAssertNil(WebDAVTransport.parseRange("bytes 5/9-10"))
    }

    func testHouseholdGrantBindsAnExactFolderToOneSource() {
        let source = UUID()
        let profile = HouseholdProfile(name: "Viewer", allowedFolders: [HouseholdFolder(sourceID: source, path: "Kids", caseSensitive: true)])
        XCTAssertTrue(HouseholdPolicy.allowsPath(profile: profile, sourceID: source, path: "Kids/Film.mp4", caseSensitive: true))
        XCTAssertFalse(HouseholdPolicy.allowsPath(profile: profile, sourceID: source, path: "kids/Film.mp4", caseSensitive: true))
        XCTAssertFalse(HouseholdPolicy.allowsPath(profile: profile, sourceID: UUID(), path: "Kids/Film.mp4", caseSensitive: true))
    }
}
