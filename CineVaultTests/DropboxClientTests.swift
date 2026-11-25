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

    func testDownloadUsesAuthorizedBoundedRangeAndStableFileID() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DropboxFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = try DropboxClient(appKey: "fixture-app", callback: XCTUnwrap(URL(string: "https://fixture.example/oauth/dropbox")),
                                       session: session)
        let body = try await client.read(fileID: "id:fixture", offset: 5, length: 5, accessToken: "fixture")
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "56789")

        for offset in [Int64(0), 1, 2, 3] {
            do {
                _ = try await client.read(fileID: "id:fixture", offset: offset, length: 5, accessToken: "fixture")
                XCTFail("Invalid response for offset \(offset) was accepted")
            } catch DropboxClientError.invalidResponse where offset != 0 {
                continue
            } catch DropboxClientError.http(200) where offset == 0 {
                continue
            }
        }
    }

    func testFolderListingFollowsCursorsAcrossAnEmptyPage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DropboxFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = try DropboxClient(appKey: "fixture-app", callback: XCTUnwrap(URL(string: "https://fixture.example/oauth/dropbox")),
                                       session: session)

        var names: [String] = []
        try await client.listFolder(path: "", accessToken: "fixture") { entries in
            names.append(contentsOf: entries.map(\.name))
        }
        XCTAssertEqual(names, ["Film.mp4"])
    }
}

private final class DropboxFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard request.httpMethod == "POST", request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture",
              let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        switch (url.host, url.path) {
        case ("content.dropboxapi.com", "/2/files/download"):
            guard request.value(forHTTPHeaderField: "Accept-Encoding") == "identity",
                  let argument = request.value(forHTTPHeaderField: "Dropbox-API-Arg"),
                  let parsed = try? JSONDecoder().decode([String: String].self, from: Data(argument.utf8)),
                  parsed["path"] == "id:fixture" else {
                respond(400, headers: [:], body: "")
                return
            }
            switch request.value(forHTTPHeaderField: "Range") {
            case "bytes=5-9": respond(206, headers: ["Content-Range": "bytes 5-9/10", "Content-Length": "5"], body: "56789")
            case "bytes=0-4": respond(200, headers: [:], body: "0123456789")
            case "bytes=1-5": respond(206, headers: ["Content-Range": "bytes 1-5/5"], body: "12345")
            case "bytes=2-6": respond(206, headers: ["Content-Range": "bytes 2-6/10"], body: "23")
            case "bytes=3-7": respond(206, headers: ["Content-Range": "bytes 3-7/10/20"], body: "34567")
            default: respond(416, headers: [:], body: "")
            }
        case ("api.dropboxapi.com", "/2/files/list_folder"):
            respond(200, headers: [:], body: #"{"entries":[],"cursor":"page2","has_more":true}"#)
        case ("api.dropboxapi.com", "/2/files/list_folder/continue"):
            respond(200, headers: [:],
                    body: #"{"entries":[{".tag":"file","name":"Film.mp4","id":"id:fixture","size":10}],"cursor":"end","has_more":false}"#)
        default: respond(404, headers: [:], body: "")
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
