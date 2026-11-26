import Foundation
import XCTest
@testable import CineVault

final class PlexMediaClientTests: XCTestCase {
    private let deviceID = "388619aa-451b-4ef5-8f08-990485839914"

    func testPinPollingAndServerDiscoveryUseTheAccountCredentialOnlyAtPlex() async throws {
        let client = try PlexAccountClient(deviceID: deviceID) { request, _, status in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.host, "plex.tv")
            #if os(iOS)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Platform"), "iOS")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Device"), "iPhone")
            #else
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Platform"), "tvOS")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Device"), "Apple TV")
            #endif
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Client-Identifier"), "388619aa-451b-4ef5-8f08-990485839914")
            XCTAssertFalse(url.absoluteString.contains("account-token"))
            let body: String
            switch url.path {
            case "/api/v2/pins":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(url.query, "strong=false")
                XCTAssertNil(request.value(forHTTPHeaderField: "X-Plex-Token"))
                body = #"{"id":14,"code":"ABCD","expiresIn":45}"#
            case "/api/v2/pins/14":
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(url.query, "code=ABCD")
                XCTAssertNil(request.value(forHTTPHeaderField: "X-Plex-Token"))
                body = #"{"authToken":"account-token"}"#
            case "/api/v2/resources":
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Token"), "account-token")
                body = """
                    [
                      {"name":"Fixture","clientIdentifier":"server","provides":"server","accessToken":"server-token","connections":[
                        {"uri":"https://fixture.example:32400","local":true,"relay":false}
                      ]},
                      {"name":"Client","clientIdentifier":"client","provides":"player","connections":[]}
                    ]
                    """
            default:
                XCTFail("Unexpected Plex account request")
                throw PlexAccountError.invalidResponse
            }
            return (Data(body.utf8), try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
        }
        let pin = try await client.beginLink()
        let result = try await client.pollLink(pin)
        let token = try XCTUnwrap(result)
        let servers = try await client.listServers(accountToken: token)
        XCTAssertEqual(servers.map(\.name), ["Fixture"])
        XCTAssertEqual(servers.first?.accessToken, "server-token")
    }

    func testCatalogPaginationAndRangeReadsKeepCredentialOnSelectedServer() async throws {
        let client = try makeMediaClient { request, limit, status in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.host, "fixture.example")
            XCTAssertEqual(url.port, 32400)
            #if os(iOS)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Platform"), "iOS")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Device"), "iPhone")
            #else
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Platform"), "tvOS")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Device"), "Apple TV")
            #endif
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Token"), "server-token")
            XCTAssertNil(url.query)
            let data: Data
            var headers: [String: String] = [:]
            switch url.path {
            case "/library/sections":
                data = Data(#"{"MediaContainer":{"size":1,"Directory":[{"key":"1","title":"Movies","type":"movie"}]}}"#.utf8)
            case "/library/sections/1/all":
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Container-Size"), "100")
                if request.value(forHTTPHeaderField: "X-Plex-Container-Start") == "0" {
                    data = Data("""
                        {"MediaContainer":{"size":1,"totalSize":2,"offset":0,"Metadata":[
                          {"ratingKey":"7","type":"movie","title":"First","Media":[
                            {"Part":[{"key":"/library/parts/9/1500/file.mp4","size":10,"container":"mp4"}]},
                            {"Part":[{"key":"https://other.example/library/parts/1/file.mp4","size":10}]},
                            {"Part":[{"key":"/library/parts/1/../file.mp4","size":10}]}
                          ]}
                        ]}}
                        """.utf8)
                } else {
                    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Container-Start"), "1")
                    data = Data(#"{"MediaContainer":{"size":1,"totalSize":2,"offset":1,"Metadata":[{"ratingKey":"8","type":"movie","title":"Second"}]}}"#.utf8)
                }
            case "/library/parts/9/1500/file.mp4":
                XCTAssertEqual(status, 206)
                XCTAssertEqual(limit, 5)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=5-9")
                headers["Content-Range"] = "bytes 5-9/10"
                data = Data("56789".utf8)
            default:
                XCTFail("Unexpected Plex media request")
                throw PlexAccountError.invalidResponse
            }
            return (data, try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)))
        }

        let sections = try await client.libraries()
        var items: [PlexMediaClient.CatalogItem] = []
        try await client.catalog(in: XCTUnwrap(sections.first)) { items += $0 }
        XCTAssertEqual(items.map(\.title), ["First", "Second"])
        let parts = client.singleFileParts(for: try XCTUnwrap(items.first))
        XCTAssertEqual(parts.count, 1)
        let part = try XCTUnwrap(parts.first)
        let data = try await client.read(part, offset: 5, length: 5)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "56789")

        let otherClient = try makeMediaClient(serverID: "other") { _, _, _ in
            XCTFail("A part from a different server must not result in a request")
            throw PlexAccountError.invalidResponse
        }
        do {
            _ = try await otherClient.read(part, offset: 5, length: 5)
            XCTFail("Expected server binding to reject this media part")
        } catch PlexAccountError.invalidResponse { }
    }

    private func makeMediaClient(serverID: String = "fixture", exchange: @escaping PlexMediaClient.Exchange) throws -> PlexMediaClient {
        let data = Data("""
            {"name":"Fixture","clientIdentifier":"\(serverID)","provides":"server","accessToken":"server-token","connections":[
              {"uri":"https://fixture.example:32400","local":true,"relay":false}
            ]}
            """.utf8)
        let server = try JSONDecoder().decode(PlexAccountClient.Server.self, from: data)
        return try PlexMediaClient(server: server, connection: XCTUnwrap(server.secureConnections.first), deviceID: deviceID, exchange: exchange)
    }
}
