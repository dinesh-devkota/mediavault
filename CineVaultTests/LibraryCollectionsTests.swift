import CineVaultCore
import Foundation
import SwiftData
import XCTest
@testable import CineVault

@MainActor final class LibraryCollectionsTests: XCTestCase {
    private func movie(_ path: String, title: String = "Feature", year: Int? = 2020, source: MediaSource? = nil) -> Movie {
        let item = Movie(filePath: path, fileSize: 100, source: source ?? MediaSource(name: "Fixture", host: "fixture.invalid", share: "Media", rootPath: "", username: ""))
        item.resetToFileName(); item.setTitle(title); item.year = year; item.parsedYear = year
        return item
    }
    func testVersionsRequireStableIdentityOrKnownYearAndKeepFileHistory() {
        let first = movie("Movies/Feature (2020).mp4"), second = movie("Movies/Feature (2020) Extended.mkv")
        first.playbackPosition = 12; second.playbackPosition = 70; second.isWatched = true
        XCTAssertEqual(MovieVersions.groups([first, second]).count, 1)
        XCTAssertEqual(MovieVersions.groups([first, second])[0].movies.count, 2)
        XCTAssertEqual(first.playbackPosition, 12); XCTAssertEqual(second.playbackPosition, 70); XCTAssertFalse(first.isWatched)
        XCTAssertNotEqual(MovieVersions.key(first), MovieVersions.key(movie("Feature (2022).mp4", year: 2022)))
        XCTAssertNotEqual(MovieVersions.key(movie("One.mp4", year: nil)), MovieVersions.key(movie("Two.mp4", year: nil)))
        first.tmdbID = 10; second.tmdbID = 11
        XCTAssertEqual(MovieVersions.groups([first, second]).count, 2)
        second.tmdbID = 10; second.setTitle("Different local title")
        XCTAssertEqual(MovieVersions.groups([first, second]).count, 1)
        XCTAssertNotEqual(MovieVersions.key(movie("TV/Show.S01E01.mp4")), MovieVersions.key(movie("TV/Show.S01E02.mp4")))
        XCTAssertNotEqual(MovieVersions.key(movie("Music/a.mp3")), MovieVersions.key(movie("Music/b.mp3")))
    }
    func testVersionLabelsRespectResolutionTokenBoundariesAndEdition() {
        let item = movie("The 4Kings (2020).mp4")
        XCTAssertFalse(MovieVersions.label(item).contains("4K"))
        let extended = movie("Film (2020) 2160p Extended.mkv")
        XCTAssertTrue(MovieVersions.label(extended).contains("4K")); XCTAssertTrue(MovieVersions.label(extended).contains("Extended"))
        extended.localEdition = "Restored festival cut"
        XCTAssertTrue(MovieVersions.label(extended).hasPrefix("Restored festival cut"))
    }
    func testFranchiseRequiresTwoTitlesAndCountsVersionsOnlyOnce() {
        let one = movie("Feature (2020).mp4"), cut = movie("Feature (2020) Extended.mkv")
        let sequel = movie("Sequel (2022).mp4", title: "Sequel", year: 2022)
        [one, cut, sequel].forEach { $0.collectionName = "A Saga" }
        XCTAssertTrue(MediaCollections.visible(library: [one, cut], custom: []).isEmpty)
        let group = MediaCollections.visible(library: [one, cut, sequel], custom: []).first
        XCTAssertEqual(group?.titleCount, 2); XCTAssertEqual(group?.movies.count, 3)
        sequel.isHidden = true
        XCTAssertTrue(MediaCollections.visible(library: [one, cut, sequel], custom: []).isEmpty)
        let series = [movie("TV/Show.S01E01.mp4"), movie("TV/Show.S01E02.mp4")]
        let personal = NamedMediaCollection(id: UUID(), name: "Weekend", movieIDs: (series + [one, cut]).map(\.id))
        XCTAssertEqual(MediaCollections.visible(library: series + [one, cut], custom: [personal]).first?.titleCount, 2)
    }
    func testPersonalCollectionsPersistCRUDAndExcludeUnavailableItems() throws {
        let suite = "MediaVault.CollectionTests.\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let household = HouseholdStore(defaults: defaults, read: { nil }, write: { _ in })
        let store = LibraryCollectionsStore(defaults: defaults, household: household), session = household.sessionToken
        let one = movie("Movies/Feature.mp4"), hidden = movie("Movies/Private.mp4"), photo = movie("Photos/poster.jpg")
        hidden.isHidden = true
        let id = try store.create(name: " Weekend ", movies: [one, one, hidden, photo], session: session)
        XCTAssertEqual(store.collections.first?.name, "Weekend"); XCTAssertEqual(store.collections.first?.movieIDs, [one.id])
        let reloaded = LibraryCollectionsStore(defaults: defaults, household: household)
        XCTAssertEqual(reloaded.collections, store.collections)
        XCTAssertThrowsError(try store.create(name: "weekend", movies: [], session: session))
        try store.rename(id, name: "Favourites", session: session)
        let two = movie("Movies/Sequel.mp4", title: "Sequel")
        try store.add([two], to: id, session: session)
        try store.remove(movieIDs: [one.id], from: id, session: session)
        XCTAssertEqual(store.collections.first?.movieIDs, [two.id]); XCTAssertEqual(store.collections.first?.name, "Favourites")
        two.source?.rootPath = "Other"
        XCTAssertFalse(LibraryCollectionsStore.available(two, household: household))
        try store.delete(id, session: session); XCTAssertTrue(store.collections.isEmpty)
        XCTAssertThrowsError(try store.create(name: "Stale", movies: [], session: UUID()))
    }
    func testProfileSwitchHidesCollectionNamesAndInvalidatesEdits() async throws {
        let suite = "MediaVault.CollectionProfiles.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var credentials: String?
        let household = HouseholdStore(defaults: defaults, read: { credentials }, write: { credentials = $0 })
        let store = LibraryCollectionsStore(household: household)
        try await household.setupAsync(pin: "328614", confirmation: "328614", intent: household.authenticationToken)
        let admin = try XCTUnwrap(household.profiles.first(where: \.isAdmin)?.id)
        try await household.unlockAsync(admin, pin: "328614", intent: household.authenticationToken)
        let adultSession = household.sessionToken
        _ = try store.create(name: "Private adult collection", movies: [], session: adultSession)
        let viewer = HouseholdProfile(name: "Viewer")
        defer { UserDefaults.standard.removePersistentDomain(forName: "mediavault.viewer.\(viewer.id.uuidString)") }
        try await household.saveViewer(viewer, newPIN: nil, confirmation: "", adminPIN: "328614", intent: household.authenticationToken)
        try await household.unlockAsync(viewer.id, pin: "", intent: household.authenticationToken)
        XCTAssertTrue(store.collections.isEmpty)
        XCTAssertThrowsError(try store.create(name: "Wrong profile", movies: [], session: adultSession))
        _ = try store.create(name: "Viewer favourites", movies: [], session: household.sessionToken)
        household.lock(); XCTAssertTrue(store.collections.isEmpty)
        try await household.unlockAsync(admin, pin: "328614", intent: household.authenticationToken)
        XCTAssertEqual(store.collections.map(\.name), ["Private adult collection"])
    }

    func testOneDriveCollectionEntriesRespectExactRootAndExclusions() {
        let suite = "MediaVault.CloudCollectionTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let household = HouseholdStore(defaults: defaults, read: { nil }, write: { _ in })
        let source = MediaSource(name: "Cloud", host: "fixture.invalid", share: "folder", rootPath: "Movies", username: "")
        source.sourceProtocol = CloudFileProvider.oneDrive.rawValue
        let item = movie("Movies/Feature.mp4", source: source)
        XCTAssertTrue(LibraryCollectionsStore.available(item, household: household))
        item.filePath = "movies/Feature.mp4"
        XCTAssertFalse(LibraryCollectionsStore.available(item, household: household))
        item.filePath = "Movies/Feature.mp4"
        // Ignore rules are relative to the selected Movies root, not the share.
        source.ignoredFiles = ["Feature.mp4"]
        XCTAssertFalse(LibraryCollectionsStore.available(item, household: household))
    }
    func testLocalMetadataAndVersionHistoryPersistAcrossDatabaseReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mediavault-local-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.store")
        func withStore(_ body: (ModelContext) throws -> Void) throws {
            try autoreleasepool {
                let schema = Schema([MediaSource.self, Movie.self])
                let config = ModelConfiguration("LocalLibrary", schema: schema, url: url, cloudKitDatabase: .none)
                let container = try ModelContainer(for: schema, configurations: [config]); container.mainContext.autosaveEnabled = false
                try body(container.mainContext)
            }
        }
        try withStore { context in
            let item = movie("Movies/Feature (2020).mp4")
            let info = try LocalMetadataParser.parse(Data("<movie><title>My film</title><set>My Saga</set><edition>Extended</edition><mpaa>PG</mpaa></movie>".utf8))
            LocalMetadataService.apply(info, to: item); item.localPosterPath = "Movies/poster.png"; item.playbackPosition = 93
            context.insert(item.source!); context.insert(item); try context.save()
        }
        try withStore { context in
            let item = try XCTUnwrap(context.fetch(FetchDescriptor<Movie>()).first)
            XCTAssertEqual(item.title, "My film"); XCTAssertEqual(item.collectionName, "My Saga")
            XCTAssertEqual(item.localEdition, "Extended"); XCTAssertEqual(item.localPosterPath, "Movies/poster.png")
            XCTAssertTrue(item.localMetadataFields?.contains("certification") == true)
            XCTAssertEqual(item.playbackPosition, 93); XCTAssertNotNil(item.localMetadataSignature)
        }
    }
}
