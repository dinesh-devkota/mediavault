import Foundation
import XCTest
@testable import CineVault

final class DriveCompanionClientTests: XCTestCase {
    func testPairingPollAndRevocationUseSeparateOpaqueBearers() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = try DriveCompanionClient(endpoint: URL(string: "https://companion.example:8443/")!, session: session)
        let pairing = try await client.beginPairing()
        XCTAssertEqual(pairing.code, "AB23-CD45")
        XCTAssertEqual(pairing.verificationUrl.absoluteString, "https://companion.example:8443/pair")

        let pending = try await client.poll(CompanionProtocol.pairing(id: "pending"))
        XCTAssertNil(pending)
        let approval = try await client.poll(pairing)
        let connection = try XCTUnwrap(approval)
        XCTAssertEqual(connection.files, [CompanionProtocol.file])
        XCTAssertNotEqual(connection.token, pairing.secret)
        let catalog = try await client.catalog(token: connection.token)
        XCTAssertEqual(catalog, connection.files)
        try await client.cancel(CompanionProtocol.pairing(id: "pending"))
        try await client.disconnect(token: connection.token)
    }

    func testRefusesMismatchedOriginsAndReportsPairingExpiration() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        for address in ["http://companion.example", "https://user@companion.example", "https://companion.example/base"] {
            XCTAssertThrowsError(try DriveCompanionClient(endpoint: URL(string: address)!, session: session)) {
                XCTAssertEqual($0 as? DriveCompanionError, .invalidEndpoint)
            }
        }
        let wrongOrigin = try DriveCompanionClient(endpoint: URL(string: "https://other.example")!, session: session)
        do {
            _ = try await wrongOrigin.beginPairing()
            XCTFail("Accepted a verification URL at another origin")
        } catch DriveCompanionError.invalidResponse {}
        let client = try DriveCompanionClient(endpoint: URL(string: "https://companion.example:8443")!, session: session)
        do {
            _ = try await client.poll(CompanionProtocol.pairing(id: "expired"))
            XCTFail("Accepted an expired pairing")
        } catch DriveCompanionError.pairingExpired {}
    }

    func testReadsAnAuthenticatedExactRangeAndRefusesWrongTotal() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = try DriveCompanionClient(endpoint: URL(string: "https://companion.example:8443")!, session: session)
        let media = CompanionProtocol.file
        let bytes = try await client.read(file: media, token: CompanionProtocol.connectionToken, offset: 5, length: 5)
        XCTAssertEqual(bytes, Data("56789".utf8))
        let changedSize = DriveCompanionFile(id: media.id, name: media.name, size: 11, mimeType: media.mimeType,
                                            parentId: media.parentId)
        do {
            _ = try await client.read(file: changedSize, token: CompanionProtocol.connectionToken, offset: 5, length: 5)
            XCTFail("Accepted a range from a changed file")
        } catch DriveCompanionError.invalidRange {}
        do {
            _ = try await client.read(file: media, token: CompanionProtocol.connectionToken, offset: 9, length: 2)
            XCTFail("Accepted a range beyond the selected file")
        } catch DriveCompanionError.invalidRange {}
        do {
            _ = try await client.read(file: media, token: CompanionProtocol.revokedToken, offset: 5, length: 5)
            XCTFail("Accepted a revoked connection")
        } catch DriveCompanionError.reconnectRequired {}
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompanionProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class CompanionProtocol: URLProtocol {
    static let pollSecret = String(repeating: "p", count: 43)
    static let connectionToken = String(repeating: "c", count: 43)
    static let revokedToken = String(repeating: "r", count: 43)
    static let file = DriveCompanionFile(id: "film", name: "Drive Fixture Clip.mp4", size: 10,
                                         mimeType: "video/mp4", parentId: "parent-1")

    static func pairing(id: String) -> DriveCompanionPairing {
        DriveCompanionPairing(id: id, secret: pollSecret, verificationUrl: URL(string: "https://companion.example:8443/pair")!,
                              code: "AB23-CD45", expiresIn: 600)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, url.scheme == "https", url.query == nil else { respond(400); return }
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        let files = """
        [{"id":"film","name":"Drive Fixture Clip.mp4","size":10,"mimeType":"video/mp4","parentId":"parent-1"}]
        """
        if request.httpMethod == "POST", url.path == "/v1/pairings", authorization == nil {
            respond(201, body: """
            {"id":"approved","secret":"\(Self.pollSecret)","verificationUrl":"https://companion.example:8443/pair","code":"AB23-CD45","expiresIn":600}
            """)
        } else if url.host == "companion.example", url.port == 8443 {
            switch (request.httpMethod, url.path, authorization) {
            case ("GET", "/v1/pairings/approved", "Bearer \(Self.pollSecret)"):
                respond(200, body: """
                {"status":"approved","connection":{"token":"\(Self.connectionToken)","files":\(files)}}
                """)
            case ("GET", "/v1/pairings/pending", "Bearer \(Self.pollSecret)"):
                respond(200, body: #"{"status":"pending"}"#)
            case ("GET", "/v1/pairings/expired", "Bearer \(Self.pollSecret)"):
                respond(410)
            case ("DELETE", "/v1/pairings/pending", "Bearer \(Self.pollSecret)"),
                 ("DELETE", "/v1/connection", "Bearer \(Self.connectionToken)"):
                respond(204)
            case ("GET", "/v1/connection", "Bearer \(Self.connectionToken)"):
                respond(200, body: """
                {"files":\(files)}
                """)
            case ("GET", "/v1/files/film", "Bearer \(Self.connectionToken)"):
                guard request.value(forHTTPHeaderField: "Range") == "bytes=5-9",
                      request.value(forHTTPHeaderField: "Accept-Encoding") == "identity" else { respond(400); return }
                respond(206, headers: ["Content-Range": "bytes 5-9/10", "Content-Length": "5"], body: "56789")
            case ("GET", "/v1/files/film", "Bearer \(Self.revokedToken)"): respond(401)
            default: respond(404)
            }
        } else {
            respond(400)
        }
    }

    private func respond(_ status: Int, headers: [String: String] = [:], body: String = "") {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                                                    headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: Data(body.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
}
