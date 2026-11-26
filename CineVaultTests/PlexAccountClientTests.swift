import Foundation
import XCTest
@testable import CineVault

final class PlexAccountClientTests: XCTestCase {
    func testServerDiscoveryFiltersCleartextAndCredentialBearingAddresses() throws {
        let data = Data("""
            {"name":"Fixture","clientIdentifier":"server","provides":"server","connections":[
              {"uri":"http://fixture.example:32400","local":true,"relay":false},
              {"uri":"https://fixture.example:32400","local":true,"relay":false},
              {"uri":"https://user:password@fixture.example:32400","local":true,"relay":false},
              {"uri":"https://fixture.example:32400?token=fixture","local":true,"relay":false}
            ]}
            """.utf8)
        let server = try JSONDecoder().decode(PlexAccountClient.Server.self, from: data)
        XCTAssertEqual(server.secureConnections.map(\.uri.absoluteString), ["https://fixture.example:32400"])
    }
}
