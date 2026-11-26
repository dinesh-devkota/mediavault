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
        XCTAssertEqual(try address.url(for: "Kids #1", directory: true).absoluteString, "https://nas.example:5006/media/Kids%20%231/")
        XCTAssertEqual(try address.url(for: "", directory: true).absoluteString, "https://nas.example:5006/media/")
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

    func testFixtureChecksSignInFolderListingAndSeek() async throws {
        let address = try WebDAVAddress("https://fixture.example/media/")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebDAVTestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let denied = WebDAVTransport(address: address, username: "viewer", password: "wrong", session: session)
        do {
            _ = try await denied.list("Kids")
            XCTFail("Expected sign-in to fail")
        } catch WebDAVError.status(401) { }

        let allowed = WebDAVTransport(address: address, username: "viewer", password: "sample", session: session)
        let entries = try await allowed.list("Kids")
        XCTAssertEqual(entries.map(\.path), ["Kids/Film.mp4", "Kids/Film.en.srt", "Kids/Photo.jpg"].sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        let size = try await allowed.fileSize("Kids/Film.mp4")
        let range = try await allowed.read("Kids/Film.mp4", offset: 5, length: 5)
        XCTAssertEqual(size, 10)
        XCTAssertEqual(String(data: range, encoding: .utf8), "56789")
        do {
            _ = try await allowed.read("Kids/Film.mp4", offset: 7, length: 3)
            XCTFail("Expected truncated response to fail")
        } catch WebDAVError.shortRead { }
    }

    func testHouseholdGrantBindsAnExactFolderToOneSource() {
        let source = UUID()
        let profile = HouseholdProfile(name: "Viewer", allowedFolders: [HouseholdFolder(sourceID: source, path: "Kids", caseSensitive: true)])
        XCTAssertTrue(HouseholdPolicy.allowsPath(profile: profile, sourceID: source, path: "Kids/Film.mp4", caseSensitive: true))
        XCTAssertFalse(HouseholdPolicy.allowsPath(profile: profile, sourceID: source, path: "kids/Film.mp4", caseSensitive: true))
        XCTAssertFalse(HouseholdPolicy.allowsPath(profile: profile, sourceID: UUID(), path: "Kids/Film.mp4", caseSensitive: true))
    }
}


private final class WebDAVTestProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.example" }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        var headers: [String: String] = [:]
        let status: Int
        let body: Data
        if request.value(forHTTPHeaderField: "Authorization") != "Basic dmlld2VyOnNhbXBsZQ==" {
            status = 401
            body = Data()
        } else if request.httpMethod == "PROPFIND", request.value(forHTTPHeaderField: "Depth") == "1", URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath == "/media/Kids/" {
            let urls = ["/media/Kids/", "/media/Kids/Film.mp4", "/media/Kids/Film.en.srt", "/media/Kids/Photo.jpg"]
            let rows = urls.map { path in
                "<d:response><d:href>\(path)</d:href><d:propstat><d:prop><d:resourcetype>\(path.hasSuffix("/") ? "<d:collection/>" : "")</d:resourcetype><d:getcontentlength>10</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
            }.joined()
            status = 207
            body = Data(("<d:multistatus xmlns:d=\"DAV:\">" + rows + "</d:multistatus>").utf8)
        } else if url.path == "/media/Kids/Film.mp4", let range = request.value(forHTTPHeaderField: "Range") {
            status = 206
            switch range {
            case "bytes=0-0":
                headers["Content-Range"] = "bytes 0-0/10"
                body = Data("0".utf8)
            case "bytes=5-9":
                headers["Content-Range"] = "bytes 5-9/10"
                body = Data("56789".utf8)
            default:
                headers["Content-Range"] = "bytes 7-9/10"
                body = Data("78".utf8)
            }
        } else {
            status = 404
            body = Data()
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
