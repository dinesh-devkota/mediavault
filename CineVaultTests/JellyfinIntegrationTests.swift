import AVFoundation
import Foundation
import SwiftData
import XCTest
@testable import CineVault

@MainActor
final class JellyfinIntegrationTests: XCTestCase {
    func testSignInImportDirectPlayAndSeekOverHTTPS() async throws {
        let endpoint = "https://127.0.0.1:18896/jellyfin/"
        let id = UUID()
        let client = try JellyfinSourceConnection.client(endpoint: endpoint, sourceID: id)
        do {
            _ = try await client.signIn(username: "fixture", password: "incorrect")
            XCTFail("The fixture must reject invalid credentials.")
        } catch JellyfinClientError.status(401) { }
        let account = try await client.signIn(username: "fixture", password: "fixture-only")
        let libraries = try await client.libraries(account)
        let library = try XCTUnwrap(libraries.first)
        XCTAssertEqual(library.id, "fixture-library")

        let container = try ModelContainer(for: MediaSource.self, Movie.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let source = MediaSource(name: library.name, host: endpoint, share: library.id,
                                 rootPath: "", username: account.user.id)
        source.id = id
        source.sourceProtocol = "jellyfin"
        try source.setPassword(account.token)
        defer { try? source.setPassword("") }
        context.insert(source)
        try context.save()
        let scanner = LibraryScanner()
        await scanner.scan(source, context: context)
        let movie = try XCTUnwrap(source.movies.first, scanner.status ?? "The catalog was empty.")
        XCTAssertEqual(movie.filePath, "fixture-movie.mp4")
        XCTAssertEqual(movie.title, "Fixture Film")
        XCTAssertEqual(movie.usContentRating, "G")
        XCTAssertFalse(movie.isWatched)

        let connection = try JellyfinSourceConnection(config: source.config())
        let playback = try await connection.directPlayback(path: movie.filePath)
        let header = try await connection.client.readDirect(playback, account: account, offset: 4, length: 4)
        XCTAssertEqual(header.data, Data("ftyp".utf8))

        let prepared = try await PlaybackController.prepare(movie: movie, resume: false, services: PlaybackServices())
        let controller = try XCTUnwrap(prepared)
        defer { controller.stop() }
        let player = controller.player
        player.play()
        try await waitForPlayback(player, past: 0.5)
        let sought = expectation(description: "Seek completes")
        player.seek(to: CMTime(seconds: 8, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { completed in
            XCTAssertTrue(completed)
            sought.fulfill()
        }
        await fulfillment(of: [sought], timeout: 25)
        player.play()
        try await waitForPlayback(player, past: 8.5)
    }

    private func waitForPlayback(_ player: AVPlayer, past target: Double) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(35))
        while clock.now < deadline {
            let time = player.currentTime().seconds
            if time.isFinite, time > target { return }
            if let error = player.error ?? player.currentItem?.error { throw error }
            try await clock.sleep(for: .milliseconds(150))
        }
        XCTFail("Playback did not pass position \(target).")
    }
}
