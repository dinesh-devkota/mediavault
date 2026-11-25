import Foundation
import XCTest
@testable import CineVault

final class MediaHLSRelayTests: XCTestCase {
    func testRelayHidesUpstreamReferencesAndStopsDeliveringAfterRevocation() async throws {
        let gate = ReadGate()
        let entry = try XCTUnwrap(URL(string: "https://relay-fixture.invalid/videos/one/master.m3u8"))
        let segment = Data("synthetic segment".utf8)
        let relay = try MediaHLSRelay(transport: .init(
            entry: entry,
            resolve: { reference, parent in
                guard let url = URL(string: reference, relativeTo: parent)?.absoluteURL,
                      url.host == entry.host else { throw MediaHLSRelay.RelayError.invalidResponse }
                return url
            },
            read: { resource, _ in
                if resource == entry {
                    return .init(data: Data("#EXTM3U\n#EXTINF:2.0,\nsegment.ts?api_key=fixture-token\n#EXT-X-ENDLIST\n".utf8),
                                 contentRange: nil)
                }
                return .init(data: segment, contentRange: nil)
            }), allowsRead: { gate.canRead })
        defer { relay.stop() }
        let url = try await relay.start()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        XCTAssertEqual(url.host, "127.0.0.1")
        let (manifest, response) = try await session.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let playlist = try XCTUnwrap(String(data: manifest, encoding: .utf8))
        XCTAssertFalse(playlist.contains("fixture-token"))
        XCTAssertFalse(playlist.contains("relay-fixture.invalid"))
        let reference = try XCTUnwrap(playlist.split(separator: "\n").first { !$0.hasPrefix("#") })
        let resource = try XCTUnwrap(URL(string: String(reference), relativeTo: url)?.absoluteURL)
        XCTAssertEqual(resource.host, "127.0.0.1")
        XCTAssertNil(resource.query)
        let (expected, served) = try await session.data(from: resource)
        XCTAssertEqual((served as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(expected, segment)
        gate.revoke()
        let (blocked, denied) = try await session.data(from: resource)
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertTrue(blocked.isEmpty)
    }

    private final class ReadGate: @unchecked Sendable {
        private let lock = NSLock()
        private var allowed = true

        var canRead: Bool { lock.withLock { allowed } }
        func revoke() { lock.withLock { allowed = false } }
    }
}
