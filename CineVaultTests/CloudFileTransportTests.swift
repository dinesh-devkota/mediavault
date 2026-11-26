import Foundation
import XCTest
@testable import CineVault

final class CloudFileTransportTests: XCTestCase {
    func testResolutionUsesExactNamesAndProvesAncestryBelowTheSelectedRoot() async throws {
        let calls = CloudFixtureCalls()
        let transport = CloudFileTransport(rootID: "root", children: { id, permission in
            try permission()
            await calls.list(id)
            switch id {
            case "root":
                return [
                    .init(id: "movies", name: "Movies", isDirectory: true, size: 0),
                    .init(id: "duplicate-1", name: "Duplicate", isDirectory: true, size: 0),
                    .init(id: "duplicate-2", name: "Duplicate", isDirectory: true, size: 0),
                    .init(id: "unsafe", name: "../Other", isDirectory: true, size: 0),
                    .init(id: "root", name: "Cycle", isDirectory: true, size: 0)
                ]
            case "movies":
                return [
                    .init(id: "cover-uppercase", name: "Film.jpg", isDirectory: false, size: 12),
                    .init(id: "cover-lowercase", name: "film.jpg", isDirectory: false, size: 12)
                ]
            default:
                XCTFail("Used an identifier outside the configured fixture source")
                return []
            }
        }, rangeRead: { file, position, length, permission in
            try permission()
            await calls.read(file.id)
            XCTAssertEqual(position, 4)
            XCTAssertEqual(length, 4)
            return Data("ftyp".utf8)
        })
        let displayed = try await transport.list("", check: {})
        XCTAssertEqual(displayed.map(\.path), ["Movies"])
        let bytes = try await transport.read("Movies/Film.jpg", offset: 4, length: 4, check: {})
        XCTAssertEqual(bytes, Data("ftyp".utf8))
        for excluded in ["movies/Film.jpg", "Movies/FILM.jpg", "../Movies/Film.jpg", "Duplicate/Film.jpg",
                         "Movies/%2e%2e/Film.jpg", "Cycle/Movies/Film.jpg"] {
            do {
                _ = try await transport.read(excluded, offset: 4, length: 4, check: {})
                XCTFail("Resolved a path outside the exact selected folder: \(excluded)")
            } catch CloudFileError.invalidPath {}
        }
        let remoteReads = await calls.files
        XCTAssertEqual(remoteReads, ["cover-uppercase"])
    }

    func testPermissionRevocationDiscardsBytesAndPreventsLaterRemoteReads() async throws {
        let permission = CloudFixturePermission()
        let calls = CloudFixtureCalls()
        let transport = CloudFileTransport(rootID: "root", children: { _, check in
            try check()
            return [.init(id: "film", name: "Film.mp4", isDirectory: false, size: 10)]
        }, rangeRead: { item, _, count, check in
            try check()
            await calls.read(item.id)
            permission.revoke()
            return Data(repeating: 0, count: count)
        })
        let check: CloudFileTransport.Permission = { try permission.check() }
        for _ in 0..<2 {
            do {
                _ = try await transport.read("Film.mp4", offset: 2, length: 3, check: check)
                XCTFail("Returned bytes after household access was revoked")
            } catch HouseholdError.denied {}
        }
        let reads = await calls.files
        XCTAssertEqual(reads, ["film"])
    }
}

private actor CloudFixtureCalls {
    private(set) var directories: [String] = []
    private(set) var files: [String] = []
    func list(_ id: String) { directories.append(id) }
    func read(_ id: String) { files.append(id) }
}

private final class CloudFixturePermission: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true
    func revoke() { lock.lock(); defer { lock.unlock() }; allowed = false }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if !allowed { throw HouseholdError.denied }
    }
}
