import CineVaultCore
import Foundation
import SwiftData
import XCTest
@testable import CineVault

@MainActor final class LocalMetadataImportTests: XCTestCase {
    private func fixture() throws -> (ModelContainer, MediaSource, Movie) {
        let container = try ModelContainer(for: MediaSource.self, Movie.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let source = MediaSource(name: "Local fixture", host: "fixture.invalid", share: "Media", rootPath: "", username: "")
        let movie = Movie(filePath: "Movies/Film (2020).mp4", fileSize: 100, source: source)
        movie.resetToFileName()
        container.mainContext.insert(source); container.mainContext.insert(movie); try container.mainContext.save()
        return (container, source, movie)
    }
    private func nfo(_ xml: String) throws -> LocalMediaMetadata { try LocalMetadataParser.parse(Data(xml.utf8)) }

    func testLocalMetadataClassifiesWithoutTMDBAndNeverChangesViewingHistory() throws {
        let (_, _, movie) = try fixture()
        movie.playbackPosition = 73; movie.isWatched = true; movie.isWatchlisted = true
        LocalMetadataService.apply(try nfo("<movie><title>Local Documentary</title><genre>Documentary</genre><mpaa>PG</mpaa><set>Home Set</set></movie>"), to: movie)
        XCTAssertEqual(movie.title, "Local Documentary"); XCTAssertEqual(movie.mediaKind, .documentary)
        XCTAssertEqual(movie.collectionName, "Home Set"); XCTAssertEqual(movie.usContentRating, "PG")
        XCTAssertEqual(movie.playbackPosition, 73); XCTAssertTrue(movie.isWatched); XCTAssertTrue(movie.isWatchlisted)
        XCTAssertFalse(movie.metadataFetched, "Local import does not claim online metadata was fetched.")
    }

    func testChangedOrRemovedLocalRatingFailsClosedAndManualEditsWin() throws {
        let (_, _, movie) = try fixture()
        LocalMetadataService.apply(try nfo("<movie><title>Local title</title><mpaa>PG</mpaa><edition>Extended</edition></movie>"), to: movie)
        XCTAssertEqual(movie.usContentRating, "PG")
        LocalMetadataService.apply(try nfo("<movie><title>New title</title></movie>"), to: movie)
        XCTAssertNil(movie.usContentRating); XCTAssertNil(movie.usContentRatingFetched); XCTAssertNil(movie.localEdition)
        LocalMetadataService.clearOverrides(movie)
        XCTAssertNil(movie.localMetadataImported); XCTAssertNil(movie.localMetadataFields); XCTAssertEqual(movie.title, movie.parsedTitle)
        movie.isLocked = true; movie.setTitle("My manual title"); movie.usContentRating = "R"
        LocalMetadataService.apply(try nfo("<movie><title>Sidecar title</title><mpaa>G</mpaa></movie>"), to: movie)
        XCTAssertEqual(movie.title, "My manual title"); XCTAssertEqual(movie.usContentRating, "R")
    }

    func testPartialNFOAllowsMissingOnlineDetailsWithoutOverwritingLocalFields() async throws {
        let (_, _, movie) = try fixture()
        LocalMetadataService.apply(try nfo("<movie><title>My local title</title><mpaa>Not Rated</mpaa><set>Local Saga</set></movie>"), to: movie)
        let service = MetadataService(requestData: { request in
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"id":42,"title":"Online title","overview":"Online plot","poster_path":"/poster.jpg","belongs_to_collection":{"id":5,"name":"Online Saga"},"release_dates":{"results":[{"iso_3166_1":"US","release_dates":[{"certification":"PG"}]}]}}"#.utf8), response)
        }, readAPIKey: { "fixture" })
        let applied = try await service.apply(tmdbID: 42, to: movie)
        XCTAssertTrue(applied)
        XCTAssertEqual(movie.title, "My local title"); XCTAssertEqual(movie.overview, "Online plot"); XCTAssertEqual(movie.posterPath, "/poster.jpg")
        XCTAssertEqual(movie.collectionName, "Local Saga"); XCTAssertNil(movie.usContentRating)
    }

    func testImportRecognizesOnlyRelatedArtworkAndRetainsStandalonePhotos() async throws {
        let (container, source, movie) = try fixture()
        let poster = Movie(filePath: "Movies/Film (2020)-poster.png", fileSize: 10, source: source)
        let photo = Movie(filePath: "Photos/poster.jpg", fileSize: 10, source: source)
        container.mainContext.insert(poster); container.mainContext.insert(photo); try container.mainContext.save()
        let bytes = Data("<movie><title>Imported</title><year>2020</year><genre>Documentary</genre></movie>".utf8)
        let service = LocalMetadataService(list: { _, directory in
            XCTAssertEqual(directory, "Movies")
            return [NASDirectoryEntry(name: "Film (2020).nfo", isDirectory: false), NASDirectoryEntry(name: "Film (2020)-poster.png", isDirectory: false)]
        }, size: { _, _ in Int64(bytes.count) }, read: { _, _, length in XCTAssertEqual(length, bytes.count); return bytes })
        let found = try await service.importFiles(source: source, context: container.mainContext, config: source.config())
        XCTAssertEqual(found, [poster.filePath]); XCTAssertEqual(movie.localPosterPath, poster.filePath)
        XCTAssertEqual(movie.title, "Imported"); XCTAssertTrue(poster.isMissing); XCTAssertFalse(photo.isMissing)
    }

    func testMalformedAndOversizeNFOsDoNotFailScanOrApplyUnsafeMetadata() async throws {
        let (container, source, movie) = try fixture()
        let names = [NASDirectoryEntry(name: "Film (2020).nfo", isDirectory: false)]
        let broken = LocalMetadataService(list: { _, _ in names }, size: { _, _ in 12 }, read: { _, _, _ in Data("<movie>oops!!".utf8) })
        _ = try await broken.importFiles(source: source, context: container.mainContext, config: source.config())
        XCTAssertNil(movie.localMetadataImported)
        let tooLarge = LocalMetadataService(list: { _, _ in names }, size: { _, _ in Int64(LocalMetadataParser.maximumBytes + 1) }, read: { _, _, _ in XCTFail("Oversized NFO must not be read"); return Data() })
        _ = try await tooLarge.importFiles(source: source, context: container.mainContext, config: source.config())
        XCTAssertNil(movie.localMetadataImported)
    }

    func testDelayedSidecarCannotApplyAfterSourceChanges() async throws {
        let (container, source, movie) = try fixture()
        let bytes = Data("<movie><title>Wrong source</title></movie>".utf8)
        let service = LocalMetadataService(list: { _, _ in [NASDirectoryEntry(name: "Film (2020).nfo", isDirectory: false)] },
            size: { _, _ in Int64(bytes.count) }, read: { _, _, _ in source.rootPath = "Different"; return bytes })
        do { _ = try await service.importFiles(source: source, context: container.mainContext, config: source.config()); XCTFail("Source change should invalidate reads") }
        catch { XCTAssertEqual(error as? SMBError, .sourceChanged) }
        XCTAssertNotEqual(movie.title, "Wrong source")
    }
}
