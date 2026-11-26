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

    func testReadsSharedDriveMediaByExactRange() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoogleDriveFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = GoogleDriveClient(session: session)

        let body = try await client.read(fileID: "film", offset: 5, length: 5, resourceKey: "resource",
                                         accessToken: "fixture")
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "56789")

        for offset in [Int64(0), 1, 2] {
            do {
                _ = try await client.read(fileID: "film", offset: offset, length: 5, resourceKey: "resource",
                                          accessToken: "fixture")
                XCTFail("Invalid response for offset \(offset) was accepted")
            } catch GoogleDriveError.invalidResponse where offset != 0 {
                continue
            } catch GoogleDriveError.http(200) where offset == 0 {
                continue
            }
        }
    }

    func testFolderListingRetainsResourceKeysAndFollowsNextPage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoogleDriveFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = GoogleDriveClient(session: session)

        var items: [GoogleDriveClient.Entry] = []
        try await client.listChildren(parent: "collection", resourceKey: "resource", accessToken: "fixture") { entries in
            items.append(contentsOf: entries)
        }
        XCTAssertEqual(items.map(\.id), ["folder", "film"])
        XCTAssertEqual(items.map(\.resourceKey), [nil, "mediaKey"])
        XCTAssertEqual(items.map(\.isFolder), [true, false])
    }
}

private final class GoogleDriveFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard request.httpMethod == "GET", request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture",
              let url = request.url, url.host == "www.googleapis.com",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let query = components.queryItems,
              query.contains(URLQueryItem(name: "supportsAllDrives", value: "true")) else {
            respond(400, headers: [:], body: "")
            return
        }
        if url.path == "/drive/v3/files" {
            guard query.contains(URLQueryItem(name: "q", value: "'collection' in parents and trashed = false")),
                  query.contains(URLQueryItem(name: "includeItemsFromAllDrives", value: "true")),
                  request.value(forHTTPHeaderField: "X-Goog-Drive-Resource-Keys") == "collection/resource" else {
                respond(400, headers: [:], body: "")
                return
            }
            if query.contains(URLQueryItem(name: "pageToken", value: "second+page")) {
                respond(200, headers: [:],
                        body: #"{"files":[{"id":"film","name":"Film.mp4","mimeType":"video/mp4","size":"10","resourceKey":"mediaKey"}]}"#)
            } else {
                respond(200, headers: [:],
                        body: #"{"files":[{"id":"folder","name":"Archive","mimeType":"application/vnd.google-apps.folder"}],"nextPageToken":"second+page"}"#)
            }
            return
        }
        guard url.path == "/drive/v3/files/film", query.contains(URLQueryItem(name: "alt", value: "media")),
              request.value(forHTTPHeaderField: "X-Goog-Drive-Resource-Keys") == "film/resource",
              request.value(forHTTPHeaderField: "Accept-Encoding") == "identity" else {
            respond(400, headers: [:], body: "")
            return
        }
        switch request.value(forHTTPHeaderField: "Range") {
        case "bytes=5-9": respond(206, headers: ["Content-Range": "bytes 5-9/10", "Content-Length": "5"], body: "56789")
        case "bytes=0-4": respond(200, headers: [:], body: "0123456789")
        case "bytes=1-5": respond(206, headers: ["Content-Range": "bytes 1-5/10/20"], body: "12345")
        case "bytes=2-6": respond(206, headers: ["Content-Range": "bytes 2-6/10"], body: "23")
        default: respond(416, headers: [:], body: "")
        }
    }

    override func stopLoading() {}

    private func respond(_ status: Int, headers: [String: String], body: String) {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status,
                                                                    httpVersion: "HTTP/1.1", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
