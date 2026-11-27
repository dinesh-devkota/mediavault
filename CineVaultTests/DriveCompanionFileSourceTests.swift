import CineVaultCore
import Foundation
import XCTest
@testable import CineVault
#if os(tvOS)
import AVFoundation
import SwiftData
#endif

final class DriveCompanionFileSourceTests: XCTestCase {
    func testSelectedMediaScansAndSeeksThroughTheSharedFileService() async throws {
        let files = [
            file("video", "Film.mp4"),
            file("photo", "Landscape.jpg"),
            file("subtitle", "Film.en.srt"),
        ]
        let reads = DriveReadFixture()
        let transport = try DriveCompanionFileSource.transport(files: files) { file, offset, count in
            try await reads.read(file, offset: offset, count: count)
        }
        let config = config(UUID())
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let household = HouseholdStore(defaults: defaults, read: { nil }, write: { _ in }, erase: {})
        let service = SMBService(cloudHousehold: household, cloudTransport: { provider, _ in
            XCTAssertEqual(provider, .googleDrive)
            return transport
        })
        let imported = try await service.scanMedia(config) { _ in }
        XCTAssertEqual(Set(imported.map(\.path)), ["Film.mp4", "Landscape.jpg"])

        let video = try await service.read(config, path: "Film.mp4", offset: 4, length: 4)
        XCTAssertEqual(video, Data("ftyp".utf8))
        let image = try await service.read(config, path: "Landscape.jpg", offset: 0, length: 2)
        XCTAssertEqual(image, Data([0xff, 0xd8]))
        for path in ["film.mp4", "Other.mov", "folder/Film.mp4", "../Film.mp4"] {
            do {
                _ = try await service.read(config, path: path, offset: 0, length: 1)
                XCTFail("Unexpected access to \(path)")
            } catch CloudFileError.invalidPath {}
        }
        let requested = await reads.requested
        XCTAssertEqual(requested, ["video", "photo"])
    }

    #if os(tvOS)
    @MainActor
    func testReconnectedDriveSelectionLoadsNativeAssetThroughHTTPS() async throws {
        let endpoint = try XCTUnwrap(URL(string: "https://127.0.0.1:18477"))
        let client = try DriveCompanionClient(endpoint: endpoint)
        let initial = try await approvedFixtureSelection(client)
        addTeardownBlock { try? await client.disconnect(token: initial.token) }

        let suite = "MediaVault.DriveCompanionPlayback.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let household = HouseholdStore(defaults: defaults, read: { nil })
        let session = household.sessionToken
        let authorize = {
            guard household.isAdmin, household.sessionIsCurrent(session) else { throw HouseholdError.denied }
        }
        let container = try ModelContainer(for: MediaSource.self, Movie.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let source = try await DriveCompanionSourceStore.create(name: "Drive playback fixture", endpoint: endpoint,
            connection: initial, context: context, authorize: authorize)
        let sourceID = source.id
        defer { _ = try? DriveCompanionFileSource.remove(sourceID) {} }
        let scanner = LibraryScanner(fetchMetadata: { _ in nil })
        await scanner.scan(source, context: context)
        XCTAssertEqual(source.movies.map(\.filePath), ["Drive Fixture Clip.mp4"], scanner.status ?? "")
        let movie = try XCTUnwrap(source.movies.first)

        let renewed = try await approvedFixtureSelection(client)
        addTeardownBlock { try? await client.disconnect(token: renewed.token) }
        XCTAssertFalse(initial.token == renewed.token, "The fixture must issue a fresh connection on reconnect.")
        try await DriveCompanionSourceStore.reconnect(source: source, endpoint: endpoint,
            connection: renewed, context: context, authorize: authorize)

        let loader = SMBResourceLoader(config: try source.config(), path: movie.filePath, household: household)
        var signature = Data()
        try await loader.streamBytes(from: 4, to: 8) { signature.append($0) }
        XCTAssertEqual(signature, Data("ftyp".utf8), "The playback loader must return the requested MP4 bytes over the renewed grant.")

        let prepared = try await PlaybackController.prepare(movie: movie, resume: false,
            services: PlaybackServices(), defaults: defaults, allowAlternative: false, household: household)
        let controller = try XCTUnwrap(prepared)
        defer { controller.stop() }
        let asset = try XCTUnwrap(controller.player.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(asset.url.scheme, SMBResourceLoader.scheme)
        XCTAssertNil(asset.url.query)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(duration.seconds, 12, accuracy: 0.1)
        XCTAssertEqual(videoTracks.count, 1)
    }

    private func approvedFixtureSelection(_ client: DriveCompanionClient) async throws -> DriveCompanionConnection {
        let pairing = try await client.beginPairing()
        do {
            let first = try await client.poll(pairing)
            let second = try await client.poll(pairing)
            XCTAssertNil(first)
            XCTAssertNil(second)
            let approved = try await client.poll(pairing)
            return try XCTUnwrap(approved, "The disposable fixture approves on the third poll.")
        } catch {
            try? await client.cancel(pairing)
            throw error
        }
    }
    #endif

    func testSubtitleDiscoveryRequiresAnExplicitSiblingFromTheSelection() throws {
        let files = [
            file("video", "Film.mp4"),
            file("selected-srt", "Film.en.srt"),
            file("selected-vtt", "Film.fr.vtt"),
            file("other-folder", "Film.es.srt", parent: "other"),
            file("unknown-parent", "Film.de.srt", parent: nil),
            file("other-film", "Other.srt"),
            file("unknown-video", "Unsorted.mp4", parent: nil),
        ]
        let names = DriveCompanionFileSource.siblingNames(for: "Film.mp4", in: files)
        let matches = files.filter { names.contains(Data($0.name.utf8)) }.compactMap {
            SubtitleFile.match(name: $0.name, videoPath: "Film.mp4", rootPath: "", caseSensitive: true)?.path
        }
        XCTAssertEqual(matches, ["Film.en.srt", "Film.fr.vtt"])
        XCTAssertTrue(DriveCompanionFileSource.siblingNames(for: "Unsorted.mp4", in: files).isEmpty)
        XCTAssertTrue(DriveCompanionFileSource.siblingNames(for: "film.mp4", in: files).isEmpty)
    }

    func testReconnectKeepsTheExactSelectionAndRejectsAmbiguousPaths() throws {
        let film = file("video", "Film.mp4")
        let image = file("photo", "Landscape.jpg")
        XCTAssertTrue(DriveCompanionFileSource.sameSelection([film, image], [image, film]))
        XCTAssertFalse(DriveCompanionFileSource.sameSelection([film], [file("different", film.name)]))
        XCTAssertFalse(DriveCompanionFileSource.sameSelection([film], [file(film.id, "film.mp4")]))
        XCTAssertFalse(DriveCompanionFileSource.sameSelection([film], [file(film.id, film.name, parent: nil)]))
        XCTAssertThrowsError(try DriveCompanionFileSource.validated([film, file("different", film.name)]))
        XCTAssertThrowsError(try DriveCompanionFileSource.validated([film, file(film.id, "Other.mp4")]))
        XCTAssertThrowsError(try DriveCompanionFileSource.validated([file("outside", "../Other.mp4")]))
    }

    func testStoredReplacementAndRemovalInvalidateExistingTransports() async throws {
        let id = UUID()
        let config = config(id)
        let endpoint = try XCTUnwrap(URL(string: config.host))
        let first = DriveCompanionFileSource.Binding(endpoint: endpoint, token: "fixture-old", files: [file("video", "Film.mp4")])
        let renewed = DriveCompanionFileSource.Binding(endpoint: endpoint, token: "fixture-new", files: first.files)
        defer { _ = try? DriveCompanionFileSource.remove(id) {} }

        try DriveCompanionFileSource.save(first, id: id, replacing: nil) {}
        let transport = try DriveCompanionFileSource.transport(config)
        let initial = try await transport.list("", check: {})
        XCTAssertEqual(initial.map(\.path), ["Film.mp4"])
        try DriveCompanionFileSource.save(renewed, id: id, replacing: first) {}
        XCTAssertEqual(try DriveCompanionFileSource.saved(id), renewed)
        do {
            _ = try await transport.list("", check: {})
            XCTFail("The old transport remained active after reconnect")
        } catch SMBError.sourceChanged {}

        let active = try DriveCompanionFileSource.transport(config)
        _ = try DriveCompanionFileSource.remove(id) {}
        XCTAssertNil(try DriveCompanionFileSource.saved(id))
        do {
            _ = try await active.list("", check: {})
            XCTFail("The transport remained active after removal")
        } catch SMBError.sourceChanged {}
    }

    func testViewerNeedsAWholeSelectionGrant() {
        let id = UUID()
        var viewer = HouseholdProfile(name: "Viewer")
        func canRead(_ path: String, root: Bool = false) -> Bool {
            HouseholdPolicy.allowsPath(profile: viewer, sourceID: id, path: path, caseSensitive: true,
                                       entireSourceOnly: config(id).requiresEntireSourceGrant, allowFolderRoot: root)
        }
        XCTAssertFalse(canRead("Film.mp4"))
        viewer.allowedFolders = [HouseholdFolder(sourceID: id, path: "Movies", caseSensitive: true)]
        XCTAssertFalse(canRead("Movies/Film.mp4"))
        viewer.allowedFolders = [HouseholdFolder(sourceID: id, path: "", caseSensitive: true)]
        XCTAssertTrue(canRead("Film.mp4"))
        XCTAssertTrue(canRead("", root: true))
        XCTAssertFalse(canRead(""))
        XCTAssertFalse(canRead("../Film.mp4"))
    }

    private func file(_ id: String, _ name: String, parent: String? = "fixture-folder") -> DriveCompanionFile {
        .init(id: id, name: name, size: 120_000, mimeType: "application/octet-stream", parentId: parent)
    }

    private func config(_ id: UUID) -> SourceConfig {
        SourceConfig(id: id, host: "https://drive.fixture.invalid", share: DriveCompanionFileSource.share,
                     rootPath: "", username: "", password: "", cloudFileProvider: .googleDrive)
    }
}

private actor DriveReadFixture {
    private(set) var requested: [String] = []

    func read(_ file: DriveCompanionFile, offset: Int64, count: Int) throws -> Data {
        requested.append(file.id)
        switch (file.id, offset, count) {
        case ("video", 4, 4): return Data("ftyp".utf8)
        case ("photo", 0, 2): return Data([0xff, 0xd8])
        default: throw CloudFileError.invalidRange
        }
    }
}
