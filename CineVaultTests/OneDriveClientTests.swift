import Foundation
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

private final class OneDriveFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        return ["login.microsoftonline.com", "graph.microsoft.com", "download.fixture.example"]
            .contains(request.url?.host ?? "")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let headers = request.allHTTPHeaderFields ?? [:]
        let authenticated = request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access"
        let query = parts.queryItems ?? []
        let path = parts.path
        var status = 200
        var responseHeaders = ["Content-Type": "application/json"]
        let body: String
        switch (parts.host, path) {
        case ("login.microsoftonline.com", "/consumers/oauth2/v2.0/devicecode")
            where request.httpMethod == "POST" && !authenticated:
            body = #"{"user_code":"SAMPLE","verification_uri":"https://www.microsoft.com/link","device_code":"fixture-device","expires_in":60,"interval":1}"#
        case ("login.microsoftonline.com", "/consumers/oauth2/v2.0/token") where request.httpMethod == "POST":
            body = #"{"access_token":"fixture-access","refresh_token":"fixture-refresh","expires_in":3600}"#
        case ("graph.microsoft.com", "/v1.0/me/drive/items/root-folder/children") where authenticated:
            body = #"{"value":[{"id":"one","name":"First.mp4"}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/drives/drive-42/items/root-folder/children?$skiptoken=next"}"#
        case ("graph.microsoft.com", "/v1.0/drives/drive-42/items/root-folder/children")
            where authenticated && query.contains(URLQueryItem(name: "$skiptoken", value: "next")):
            body = #"{"value":[{"id":"two","name":"Second.mp4"}]}"#
        case ("graph.microsoft.com", "/v1.0/me/drive/items/one") where authenticated:
            body = #"{"id":"one","@microsoft.graph.downloadUrl":"https://download.fixture.example/video?sig=fixture-signature"}"#
        case ("download.fixture.example", "/video")
            where headers.keys.allSatisfy({ $0.lowercased() != "authorization" }) &&
                request.value(forHTTPHeaderField: "Range") == "bytes=4-7" &&
                query.contains(URLQueryItem(name: "sig", value: "fixture-signature")):
            status = 206
            body = "ftyp"
            responseHeaders = ["Content-Type": "video/mp4", "Content-Range": "bytes 4-7/16"]
        default:
            status = 400
            body = ""
        }
        let data = Data(body.utf8)
        responseHeaders["Content-Length"] = String(data.count)
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: responseHeaders) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension OneDriveClientTests {
    func testDeviceSignInCanonicalPaginationAndReadDoNotForwardTheGraphToken() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OneDriveFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = try OneDriveClient(clientID: "12345678-1234-1234-1234-123456789ABC", session: session)
        let challenge = try await client.beginSignIn()
        XCTAssertEqual(challenge.user_code, "SAMPLE")
        let credentials = try await client.completeSignIn(challenge)
        XCTAssertEqual(credentials.refresh_token, "fixture-refresh")
        var ids: [String] = []
        try await client.listChildren(folderID: "root-folder", accessToken: credentials.access_token) { page in
            ids += page.map(\.id)
        }
        XCTAssertEqual(ids, ["one", "two"])
        let data = try await client.read(fileID: "one", offset: 4, length: 4, accessToken: credentials.access_token)
        XCTAssertEqual(data, Data("ftyp".utf8))
    }
}
