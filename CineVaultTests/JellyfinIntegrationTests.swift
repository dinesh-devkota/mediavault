import AVFoundation
import Foundation
import SwiftData
import UIKit
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
        let movie = try XCTUnwrap(source.movies.first { $0.filePath.hasSuffix(".mp4") }, scanner.status ?? "The catalog was empty.")
        XCTAssertEqual(movie.filePath, "fixture-movie.mp4")
        XCTAssertEqual(movie.title, "Fixture Film")
        XCTAssertEqual(movie.usContentRating, "G")
        XCTAssertFalse(movie.isWatched)
        let photo = try XCTUnwrap(source.movies.first { $0.filePath.hasSuffix(".jpg") })
        let loader = PhotoImageLoader()
        let thumbnail = try await loader.image(config: source.config(), path: photo.filePath,
                                               knownSize: 0, maxPixelSize: 128)
        XCTAssertLessThanOrEqual(max(thumbnail.size.height, thumbnail.size.width), 128)
        let poster = try await loader.image(config: source.config(), path: movie.filePath,
                                            knownSize: 0, maxPixelSize: 128, artworkTag: movie.providerImageTag)
        XCTAssertLessThanOrEqual(max(poster.size.height, poster.size.width), 128)

        let restricted = HouseholdProfile(name: "Fixture viewer")
        XCTAssertFalse(HouseholdPolicy.allowsPath(profile: restricted, sourceID: source.id, path: movie.filePath, caseSensitive: true))
        let permitted = HouseholdProfile(name: "Fixture viewer", allowedFolders: [
            HouseholdFolder(sourceID: source.id, path: "", caseSensitive: true),
        ])
        XCTAssertTrue(HouseholdPolicy.allowsPath(profile: permitted, sourceID: source.id, path: movie.filePath, caseSensitive: true))
        XCTAssertFalse(HouseholdPolicy.allowsPath(profile: permitted, sourceID: UUID(), path: movie.filePath, caseSensitive: true))

        let connection = try JellyfinSourceConnection(config: source.config())
        let playback = try await connection.directPlayback(path: movie.filePath)
        let header = try await connection.client.readDirect(playback, account: account, offset: 4, length: 4)
        XCTAssertEqual(header.data, Data("ftyp".utf8))

        let prepared = try await PlaybackController.prepare(movie: movie, resume: false, services: PlaybackServices())
        let controller = try XCTUnwrap(prepared)
        defer { controller.stop() }
        let player = controller.player
        controller.subtitles.start()
        let subtitleTimeout = ContinuousClock.now.advanced(by: .seconds(15))
        while controller.subtitles.local.isEmpty, ContinuousClock.now < subtitleTimeout {
            try await Task.sleep(for: .milliseconds(100))
        }
        let track = try XCTUnwrap(controller.subtitles.local.first)
        XCTAssertEqual(track.language, "en")
        controller.subtitles.select(track.id)
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
        let captionTimeout = ContinuousClock.now.advanced(by: .seconds(2))
        while controller.subtitles.caption.isEmpty, ContinuousClock.now < captionTimeout {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(controller.subtitles.caption, "Fixture Jellyfin caption.")
        controller.stop()
        let originalID = movie.id
        movie.isWatchlisted = true
        try context.save()
        await scanner.scan(source, context: context)
        let refreshed = try XCTUnwrap(source.movies.first { $0.filePath.hasSuffix(".mp4") })
        XCTAssertEqual(source.movies.count, 2)
        XCTAssertEqual(refreshed.id, originalID)
        XCTAssertTrue(refreshed.isWatchlisted)
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
