import AVFoundation
import CineVaultCore
import Foundation
import SwiftData
import XCTest
@testable import CineVault

@MainActor
final class PlexFixtureTests: XCTestCase {
    private let endpoint = URL(string: "https://127.0.0.1:18777")!

    func testLinkPaginatedImportPlaybackSeekAndServerSubtitles() async throws {
        let device = UUID()
        let target = endpoint
        let account = try PlexAccountClient(deviceID: device.uuidString) { request, limit, status in
            let original = try XCTUnwrap(request.url)
            XCTAssertEqual(original.host, "plex.tv")
            XCTAssertEqual(original.scheme, "https")
            var routed = request
            var components = try XCTUnwrap(URLComponents(url: original, resolvingAgainstBaseURL: false))
            components.host = target.host
            components.port = target.port
            routed.url = components.url
            return try await PlexAccountClient.exchange(routed, limit: limit, expectedStatus: status)
        }
        let pin = try await account.beginLink()
        let pending = try await account.pollLink(pin)
        XCTAssertNil(pending)
        let approved = try await account.pollLink(pin)
        let accountToken = try XCTUnwrap(approved)
        let servers = try await account.listServers(accountToken: accountToken)
        let server = try XCTUnwrap(servers.first)
        XCTAssertEqual(server.id, "fixture-plex-server")
        XCTAssertNotEqual(server.accessToken, accountToken)
        let (client, sections) = try await PlexSourceConnection.connect(server, deviceID: device)
        XCTAssertEqual(client.origin, endpoint)
        XCTAssertEqual(Set(sections.map(\.id)), ["10", "20", "30"])

        let container = try model()
        let context = container.mainContext
        let library = try XCTUnwrap(sections.first { $0.id == "10" })
        let source = try makeSource(library, token: XCTUnwrap(server.accessToken), context: context, id: device)
        defer { try? Keychain.delete("source-\(source.id.uuidString)") }
        let scanner = LibraryScanner()
        await scanner.scan(source, context: context)
        XCTAssertEqual(Set(source.movies.map(\.title)), ["Fixture Movie", "Second Fixture Movie"], scanner.status ?? "")
        let movie = try XCTUnwrap(source.movies.first { $0.filePath == "PlexVideo/101.mp4" })
        let item = try await client.item(id: "101", in: library.id)
        let part = try XCTUnwrap(client.singleFileParts(for: item).first)
        let header = try await client.read(part, offset: 4, length: 4)
        XCTAssertEqual(header, Data("ftyp".utf8))
        do {
            _ = try await client.item(id: "203", in: library.id)
            XCTFail("Exact Plex library scope must be enforced before media is offered.")
        } catch PlexAccountError.invalidResponse { }
        let poster = try await PhotoImageLoader.shared.image(config: source.config(), path: movie.filePath,
                                                              knownSize: 0, maxPixelSize: 128, artworkTag: movie.providerImageTag)
        XCTAssertLessThanOrEqual(max(poster.size.height, poster.size.width), 128)

        let prepared = try await PlaybackController.prepare(movie: movie, resume: false, services: PlaybackServices())
        let controller = try XCTUnwrap(prepared)
        defer { controller.stop() }
        let player = controller.player
        controller.subtitles.start()
        let subtitleDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        while controller.subtitles.local.isEmpty, ContinuousClock.now < subtitleDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let track = try XCTUnwrap(controller.subtitles.local.first)
        XCTAssertEqual(track.language, "eng")
        controller.subtitles.select(track.id)
        player.play()
        try await waitForPlayback(player, past: 0.5)
        let sought = expectation(description: "Seek over protected Plex ranges")
        player.seek(to: CMTime(seconds: 8, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            XCTAssertTrue(finished)
            sought.fulfill()
        }
        await fulfillment(of: [sought], timeout: 25)
        player.play()
        try await waitForPlayback(player, past: 8.5)
        let captionDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while controller.subtitles.caption.isEmpty, ContinuousClock.now < captionDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(controller.subtitles.caption, "Fixture Plex caption.")
        controller.stop()

        movie.isWatchlisted = true
        let stableID = movie.id
        try context.save()
        await scanner.scan(source, context: context)
        XCTAssertEqual(source.movies.count, 2)
        XCTAssertEqual(source.movies.first { $0.isWatchlisted }?.id, stableID)
    }

    func testShowGroupingPhotosAndExplicitHouseholdGrant() async throws {
        let container = try model()
        let context = container.mainContext
        let server = PlexAccountClient.Server(name: "Fixture", clientIdentifier: "fixture-plex-server",
                                              provides: "server", accessToken: "fixture-plex-server-token", connections: [
                                                .init(uri: endpoint, local: true, relay: false),
                                              ])
        let (_, sections) = try await PlexSourceConnection.connect(server, deviceID: UUID())
        let scanner = LibraryScanner()
        let token = try XCTUnwrap(server.accessToken)
        let shows = try makeSource(XCTUnwrap(sections.first { $0.id == "20" }), token: token, context: context)
        let photos = try makeSource(XCTUnwrap(sections.first { $0.id == "30" }), token: token, context: context)
        defer {
            for source in [shows, photos] { try? Keychain.delete("source-\(source.id.uuidString)") }
        }
        await scanner.scan(shows, context: context)
        let episode = try XCTUnwrap(shows.movies.first, scanner.status ?? "")
        XCTAssertEqual(episode.title, "Fixture Episode")
        XCTAssertEqual(episode.episodeInfo?.seriesTitle, "Fixture Show")
        XCTAssertEqual(episode.episodeInfo?.season, 1)
        XCTAssertEqual(episode.episodeInfo?.episode, 2)
        XCTAssertEqual(episode.usContentRating, "TV-G")
        XCTAssertEqual(episode.seriesKey, "plex:\(shows.id.uuidString):201")

        await scanner.scan(photos, context: context)
        let photo = try XCTUnwrap(photos.movies.first, scanner.status ?? "")
        XCTAssertEqual(PhotoLibrary.albums([photo]).first?.title, photos.name)
        let suite = "MediaVault.PlexHousehold.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var credentials: String?
        let household = HouseholdStore(defaults: defaults, read: { credentials }, write: { credentials = $0 })
        let loader = PhotoImageLoader(household: household)
        let config = try photos.config()
        let image = try await loader.image(config: config, path: photo.filePath, knownSize: 0, maxPixelSize: 128)
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 128)

        let pin = "348216"
        try await household.setupAsync(pin: pin, confirmation: pin, intent: household.authenticationToken)
        let admin = try XCTUnwrap(household.profiles.first(where: \.isAdmin))
        try await household.unlockAsync(admin.id, pin: pin, intent: household.authenticationToken)
        let viewer = HouseholdProfile(name: "Fixture viewer", allowedFolders: [
            HouseholdFolder(sourceID: shows.id, path: "", caseSensitive: true),
            HouseholdFolder(sourceID: photos.id, path: "PlexPhotos", caseSensitive: true),
        ])
        try await household.saveViewer(viewer, newPIN: nil, confirmation: "", adminPIN: pin, intent: household.authenticationToken)
        try await household.unlockAsync(viewer.id, pin: "", intent: household.authenticationToken)
        XCTAssertTrue(household.allows(episode))
        XCTAssertFalse(household.allows(photo))
        do {
            _ = try await loader.image(config: config, path: photo.filePath, knownSize: 0, maxPixelSize: 128)
            XCTFail("A partial grant must block an already cached Plex photo.")
        } catch PhotoLoadingError.unavailable { }
        episode.isHidden = true
        XCTAssertFalse(household.allows(episode))
    }

    private func model() throws -> ModelContainer {
        try ModelContainer(for: MediaSource.self, Movie.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func makeSource(_ library: PlexMediaClient.Section, token: String, context: ModelContext,
                            id: UUID = UUID()) throws -> MediaSource {
        let source = MediaSource(name: library.title, host: endpoint.absoluteString, share: library.id,
                                 rootPath: "", username: "fixture-plex-server")
        source.id = id
        source.sourceProtocol = "plex"
        try source.setPassword(token)
        context.insert(source)
        try context.save()
        return source
    }

    private func waitForPlayback(_ player: AVPlayer, past target: Double) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(35))
        while ContinuousClock.now < deadline {
            let time = player.currentTime().seconds
            if time.isFinite, time > target { return }
            if let error = player.error ?? player.currentItem?.error { throw error }
            try await Task.sleep(for: .milliseconds(150))
        }
        XCTFail("Plex playback did not advance past \(target) seconds.")
    }
}
