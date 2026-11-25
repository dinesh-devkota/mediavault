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
        let (container, _, movie) = try fixture()
        defer { withExtendedLifetime(container) {} }
        movie.playbackPosition = 73; movie.isWatched = true; movie.isWatchlisted = true
        LocalMetadataService.apply(try nfo("<movie><title>Local Documentary</title><genre>Documentary</genre><mpaa>PG</mpaa><set>Home Set</set></movie>"), to: movie)
        XCTAssertEqual(movie.title, "Local Documentary"); XCTAssertEqual(movie.mediaKind, .documentary)
        XCTAssertEqual(movie.collectionName, "Home Set"); XCTAssertEqual(movie.usContentRating, "PG")
        XCTAssertEqual(movie.playbackPosition, 73); XCTAssertTrue(movie.isWatched); XCTAssertTrue(movie.isWatchlisted)
        XCTAssertFalse(movie.metadataFetched, "Local import does not claim online metadata was fetched.")
    }

    func testChangedOrRemovedLocalRatingFailsClosedAndManualEditsWin() throws {
        let (container, _, movie) = try fixture()
        defer { withExtendedLifetime(container) {} }
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
        let (container, _, movie) = try fixture()
        defer { withExtendedLifetime(container) {} }
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
    func testConfirmedSidecarRemovalReevaluatesRatingAndOutageDoesNotEraseMetadata() async throws {
        let (container, source, movie) = try fixture()
        LocalMetadataService.apply(try nfo("<movie><title>Local title</title><mpaa>PG</mpaa><edition>Extended</edition></movie>"), to: movie)
        let suite = "MediaVault.LocalRatingTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var credentials: String?
        let household = HouseholdStore(defaults: defaults, read: { credentials }, write: { credentials = $0 })
        try await household.setupAsync(pin: "328614", confirmation: "328614", intent: household.authenticationToken)
        let admin = try XCTUnwrap(household.profiles.first(where: \.isAdmin)?.id)
        try await household.unlockAsync(admin, pin: "328614", intent: household.authenticationToken)
        var viewer = HouseholdProfile(name: "Child")
        viewer.allowedFolders = [HouseholdFolder(sourceID: source.id, path: "Movies")]; viewer.maximumMovieRating = "PG"
        try await household.saveViewer(viewer, newPIN: nil, confirmation: "", adminPIN: "328614", intent: household.authenticationToken)
        try await household.unlockAsync(viewer.id, pin: "", intent: household.authenticationToken)
        XCTAssertTrue(household.allows(movie))
        let offline = LocalMetadataService(list: { _, _ in throw URLError(.notConnectedToInternet) })
        _ = try await offline.importFiles(source: source, context: container.mainContext, config: source.config())
        XCTAssertEqual(movie.title, "Local title"); XCTAssertEqual(movie.usContentRating, "PG")
        let removed = LocalMetadataService(list: { _, _ in [] })
        _ = try await removed.importFiles(source: source, context: container.mainContext, config: source.config())
        XCTAssertNil(movie.usContentRating); XCTAssertNil(movie.usContentRatingFetched); XCTAssertNil(movie.localEdition)
        XCTAssertNil(movie.localMetadataSignature); XCTAssertNil(movie.localMetadataFields)
        XCTAssertFalse(household.allows(movie), "A deleted rating sidecar cannot leave an old child-safe rating authoritative")
    }

    func testTVParentMetadataAndAllSeasonArtworkVariantsStayOutOfPhotoLibrary() async throws {
        let (container, source, movie) = try fixture()
        movie.filePath = "TV/Show/Season 01/Show.S01E01.mp4"; movie.fileName = "Show.S01E01.mp4"; movie.resetToFileName()
        let episodePath = "TV/Show/Season 01/Show.S01E01.nfo", showPath = "TV/Show/tvshow.nfo"
        let data = [episodePath: Data("<episodedetails><title>Local Pilot</title><season>1</season><episode>1</episode></episodedetails>".utf8),
                    showPath: Data("<tvshow><title>My Show</title><genre>Drama</genre><mpaa>TV-PG</mpaa><uniqueid type='tmdb'>44</uniqueid></tvshow>".utf8)]
        let art = ["TV/Show/poster.jpg", "TV/Show/poster.png", "TV/Show/season01-poster.jpg", "TV/Show/season01-poster.png", "TV/Show/Season 01/poster.png"]
        let photoRows = art.map { Movie(filePath: $0, fileSize: 10, source: source) }
        photoRows.forEach { container.mainContext.insert($0) }
        let standalone = Movie(filePath: "Photos/poster.png", fileSize: 10, source: source); container.mainContext.insert(standalone)
        try container.mainContext.save()
        let allPaths = Array(data.keys) + art
        let importer = LocalMetadataService(list: { _, directory in
            allPaths.filter { ($0 as NSString).deletingLastPathComponent == directory }
                .map { NASDirectoryEntry(name: ($0 as NSString).lastPathComponent, isDirectory: false) }
        }, size: { _, path in Int64(try XCTUnwrap(data[path]).count) }, read: { _, path, _ in try XCTUnwrap(data[path]) })
        let artwork = try await importer.importFiles(source: source, context: container.mainContext, config: source.config())
        XCTAssertEqual(movie.title, "Local Pilot"); XCTAssertEqual(movie.seriesTitle, "My Show")
        XCTAssertEqual(movie.seriesTMDBID, 44); XCTAssertEqual(movie.usContentRating, "TV-PG")
        XCTAssertEqual(movie.localPosterPath, "TV/Show/poster.jpg"); XCTAssertEqual(movie.localSeasonPosterPath, "TV/Show/Season 01/poster.png")
        XCTAssertEqual(artwork, Set(art)); XCTAssertTrue(photoRows.allSatisfy(\.isMissing)); XCTAssertFalse(standalone.isMissing)
    }

    func testMalformedEpisodeCannotInheritPermissiveSeriesRatingButTransportFailureRetainsPriorState() async throws {
        let (container, source, movie) = try fixture()
        movie.filePath = "TV/Show/Season 01/Show.S01E01.mp4"; movie.fileName = "Show.S01E01.mp4"; movie.resetToFileName()
        let episodePath = "TV/Show/Season 01/Show.S01E01.nfo", showPath = "TV/Show/tvshow.nfo"
        let restricted = try nfo("<episodedetails><title>Restricted episode</title><mpaa>TV-MA</mpaa></episodedetails>")
        let show = try nfo("<tvshow><title>Family Show</title><mpaa>TV-G</mpaa></tvshow>")
        LocalMetadataService.apply(restricted, show: show, to: movie)
        var payloads = [episodePath: Data("<episodedetails><mpaa>broken".utf8),
                        showPath: Data("<tvshow><title>Family Show</title><mpaa>TV-G</mpaa></tvshow>".utf8)]
        var transportFailure = true
        let importer = LocalMetadataService(list: { _, directory in
            payloads.keys.filter { ($0 as NSString).deletingLastPathComponent == directory }
                .map { NASDirectoryEntry(name: ($0 as NSString).lastPathComponent, isDirectory: false) }
        }, size: { _, path in Int64(try XCTUnwrap(payloads[path]).count) }, read: { _, path, _ in
            if transportFailure && path == episodePath { throw URLError(.timedOut) }
            return try XCTUnwrap(payloads[path])
        })
        _ = try await importer.importFiles(source: source, context: container.mainContext, config: source.config())
        XCTAssertEqual(movie.usContentRating, "TV-MA"); XCTAssertEqual(movie.title, "Restricted episode")
        transportFailure = false
        _ = try await importer.importFiles(source: source, context: container.mainContext, config: source.config())
        XCTAssertNil(movie.usContentRating)
        XCTAssertTrue(movie.localMetadataFields?.contains("certification") == true)
        XCTAssertFalse(HouseholdPolicy.allowsRating(movie.usContentRating, maximum: "TV-PG", values: HouseholdPolicy.tvRatings))
        XCTAssertEqual(movie.title, "Restricted episode", "A bad optional sidecar must not erase display metadata")
        payloads[episodePath] = Data("<episodedetails><title>Repaired episode</title><mpaa>TV-MA</mpaa></episodedetails>".utf8)
        _ = try await importer.importFiles(source: source, context: container.mainContext, config: source.config())
        XCTAssertEqual(movie.usContentRating, "TV-MA"); XCTAssertEqual(movie.title, "Repaired episode")
        payloads.removeValue(forKey: episodePath)
        _ = try await importer.importFiles(source: source, context: container.mainContext, config: source.config())
        XCTAssertEqual(movie.usContentRating, "TV-G", "Confirmed removal may use the valid remaining series metadata")
    }

}
