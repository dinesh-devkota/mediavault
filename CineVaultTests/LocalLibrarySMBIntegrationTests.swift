import CineVaultCore
import Foundation
import SwiftData
import XCTest
@testable import CineVault

@MainActor final class LocalLibrarySMBIntegrationTests: XCTestCase {
    func testLocalSidecarsArtworkVersionsAndFranchiseWithoutOnlineKey() async throws {
        let container = try ModelContainer(for: MediaSource.self, Movie.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let source = MediaSource(name: "Local metadata fixture", host: "127.0.0.1", port: 1445, share: "MEDIALIBRARY", rootPath: "", username: "cinevault")
        try source.setPassword("fixture-only")
        defer { try? source.setPassword("") }
        container.mainContext.insert(source); try container.mainContext.save()
        let scanner = LibraryScanner(fetchMetadata: { _ in nil })
        await scanner.scan(source, context: container.mainContext)
        XCTAssertNotNil(source.lastScanDate, scanner.status ?? "Scan did not finish")
        let rows = try container.mainContext.fetch(FetchDescriptor<Movie>())
        let films = rows.filter { $0.tmdbID == 910001 && !$0.isMissing }
        XCTAssertEqual(films.count, 2)
        XCTAssertEqual(MovieVersions.groups(films).count, 1)
        XCTAssertTrue(films.allSatisfy { $0.title == "Library Feature" && $0.localMetadataImported == true })
        let feature = try XCTUnwrap(films.first { !$0.filePath.contains("Directors") })
        let art = try XCTUnwrap(feature.localPosterPath)
        XCTAssertTrue(rows.contains { $0.filePath == art && $0.isMissing }, "Companion art is not a photo-album item")
        // AMSMB2 may prefix share-relative paths with a slash (or repeat separators
        // while walking folders). Compare canonical paths without changing saved IDs.
        let photos = rows.filter { MediaFile.isPhoto(path: $0.filePath) && !$0.isMissing }
        XCTAssertEqual(Set(photos.compactMap { ScanExclusions.normalizeFile(path: $0.filePath) }), ["Photos/poster.png"],
            "Only the standalone photograph should remain in Photos: \(photos.map(\.filePath))")
        let config = try source.config()
        let image = try await PhotoImageLoader().image(config: config, path: art, knownSize: 0, maxPixelSize: 512)
        XCTAssertNotNil(image.cgImage)
        let saga = try XCTUnwrap(MediaCollections.visible(library: rows, custom: []).first { $0.name == "Library Saga" })
        XCTAssertEqual(saga.titleCount, 2); XCTAssertEqual(saga.movies.count, 3)
        let episode = try XCTUnwrap(rows.first { $0.filePath.hasSuffix("Library Show.S01E01.mp4") })
        XCTAssertEqual(episode.seriesTitle, "Library Show"); XCTAssertEqual(episode.seasonNumber, 1); XCTAssertEqual(episode.episodeNumber, 1)
        XCTAssertNotNil(episode.localPosterPath); XCTAssertNotNil(episode.localSeasonPosterPath)
        let seasonImage = try await PhotoImageLoader().image(config: config, path: try XCTUnwrap(episode.localSeasonPosterPath), knownSize: 0, maxPixelSize: 512)
        XCTAssertNotNil(seasonImage.cgImage)
        await SMBService.shared.reset(config)
    }
}
