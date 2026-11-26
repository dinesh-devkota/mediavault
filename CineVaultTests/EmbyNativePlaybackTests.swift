import AVFoundation
import CoreVideo
import Foundation
import SwiftData
import XCTest
@testable import CineVault

@MainActor
final class EmbyNativePlaybackTests: XCTestCase {
    func testEmbyImportsRendersAndSeeksDirectAndHLSOverHTTPS() async throws {
        let endpoint = "https://127.0.0.1:18896/emby/"
        let sourceID = UUID()
        let client = try EmbySourceConnection.client(endpoint: endpoint, sourceID: sourceID)
        do {
            _ = try await client.signIn(username: "fixture-emby", password: "incorrect")
            XCTFail("The HTTPS fixture must reject incorrect credentials.")
        } catch EmbyError.http(401) {}
        let account = try await client.signIn(username: "fixture-emby", password: "fixture-only")
        let libraries = try await client.libraries(account)
        let library = try XCTUnwrap(EmbySourceConnection.libraries(libraries).first)
        XCTAssertEqual(library.Id, "fixture-emby-library")

        let container = try ModelContainer(for: MediaSource.self, Movie.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let source = MediaSource(name: library.Name, host: endpoint, share: library.Id,
                                 rootPath: "", username: account.User.Id)
        source.id = sourceID
        source.sourceProtocol = "emby"
        try source.setPassword(account.AccessToken)
        defer { try? Keychain.delete("source-\(sourceID.uuidString)") }
        context.insert(source)
        try context.save()
        let scanner = LibraryScanner()
        await scanner.scan(source, context: context)
        XCTAssertEqual(Set(source.movies.map(\.title)), ["Fixture Emby Direct", "Fixture Emby HLS"], scanner.status ?? "")
        let direct = try XCTUnwrap(source.movies.first { $0.filePath == EmbySourceConnection.path("native-direct") })
        let hls = try XCTUnwrap(source.movies.first { $0.filePath == EmbySourceConnection.path("native-hls") })

        let suite = "MediaVault.EmbyNativePlayback.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var credentials: String?
        let household = HouseholdStore(defaults: defaults, read: { credentials }, write: { credentials = $0 })
        let pin = "348216"
        try await household.setupAsync(pin: pin, confirmation: pin, intent: household.authenticationToken)
        let admin = try XCTUnwrap(household.profiles.first(where: \.isAdmin))
        try await household.unlockAsync(admin.id, pin: pin, intent: household.authenticationToken)
        let ungranted = HouseholdProfile(name: "New viewer")
        let granted = HouseholdProfile(name: "Emby viewer", allowedFolders: [
            HouseholdFolder(sourceID: sourceID, path: "", caseSensitive: true),
        ], maximumMovieRating: "G")
        for profile in [ungranted, granted] {
            try await household.saveViewer(profile, newPIN: nil, confirmation: "", adminPIN: pin,
                                           intent: household.authenticationToken)
        }
        try await household.unlockAsync(ungranted.id, pin: "", intent: household.authenticationToken)
        do {
            _ = try await PlaybackController.prepare(movie: hls, resume: false, services: PlaybackServices(),
                                                      defaults: defaults, household: household)
            XCTFail("Provider sign-in must not grant play access to a new viewer.")
        } catch PlaybackPreparationError.fileUnavailable {}
        try await household.unlockAsync(granted.id, pin: "", intent: household.authenticationToken)

        try await verifyRenderedSeek(direct, hls: false, defaults: defaults, household: household)
        try await verifyRenderedSeek(hls, hls: true, defaults: defaults, household: household)
        try await client.signOut(account)
    }

    private func verifyRenderedSeek(_ movie: Movie, hls: Bool, defaults: UserDefaults,
                                    household: HouseholdStore) async throws {
        let prepared = try await PlaybackController.prepare(movie: movie, resume: false, services: PlaybackServices(),
                                                             defaults: defaults, household: household)
        let controller = try XCTUnwrap(prepared)
        defer { controller.stop() }
        let player = controller.player
        let item = try XCTUnwrap(player.currentItem)
        let asset = try XCTUnwrap(item.asset as? AVURLAsset)
        if hls {
            XCTAssertEqual(asset.url.host, "127.0.0.1")
            XCTAssertEqual(asset.url.pathExtension, "m3u8")
            XCTAssertNil(asset.url.query)
            XCTAssertFalse(asset.url.absoluteString.contains("fixture-emby-token"))
            controller.subtitles.start()
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while controller.subtitles.local.isEmpty && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            let caption = try XCTUnwrap(controller.subtitles.local.first)
            controller.subtitles.select(caption.id)
        } else {
            XCTAssertEqual(asset.url.scheme, SMBResourceLoader.scheme)
        }

        let frames = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(frames)
        defer { item.remove(frames) }
        player.play()
        try await requireDecodedFrame(frames, player: player, item: item, in: 0.35...3.0)
        player.pause()
        let seekComplete = expectation(description: "Native seek to eight seconds for \(movie.title)")
        player.seek(to: CMTime(seconds: 8, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { completed in
            XCTAssertTrue(completed)
            seekComplete.fulfill()
        }
        await fulfillment(of: [seekComplete], timeout: 25)
        player.play()
        try await requireDecodedFrame(frames, player: player, item: item, in: 8.2...10.5)
        if hls {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while controller.subtitles.caption.isEmpty && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertEqual(controller.subtitles.caption, "Fixture Emby caption.")
        }
    }

    private func requireDecodedFrame(_ frames: AVPlayerItemVideoOutput, player: AVPlayer,
                                     item: AVPlayerItem, in expectedTime: ClosedRange<Double>) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            if item.status == .failed {
                throw try XCTUnwrap(item.error, "AVPlayer item failed without a reported error.")
            }
            let time = player.currentTime()
            if time.seconds.isFinite, expectedTime.contains(time.seconds), frames.hasNewPixelBuffer(forItemTime: time) {
                var displayed = CMTime.invalid
                if let image = frames.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayed),
                   displayed.seconds.isFinite, expectedTime.contains(displayed.seconds) {
                    XCTAssertGreaterThan(CVPixelBufferGetWidth(image), 0)
                    XCTAssertGreaterThan(CVPixelBufferGetHeight(image), 0)
                    return
                }
            }
            if time.seconds.isFinite && time.seconds > expectedTime.upperBound { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw NSError(domain: "MediaVault.EmbyNativePlayback", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "No decoded Emby video frame in \(expectedTime), player clock \(player.currentTime().seconds).",
        ])
    }
}
