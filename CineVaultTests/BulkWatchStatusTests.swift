import Foundation
import SwiftData
import XCTest
@testable import CineVault

@MainActor
final class BulkWatchStatusTests: XCTestCase {
    private func store() throws -> ModelContainer {
        try ModelContainer(for: MediaSource.self, Movie.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func add(_ path: String, source: MediaSource, context: ModelContext) -> Movie {
        let movie = Movie(filePath: path, fileSize: 100, source: source)
        movie.resetToFileName()
        context.insert(movie)
        return movie
    }

    func testSeasonChangesPersistForEveryCopyWithoutChangingOtherSeasonsOrPlayedTime() throws {
        let container = try store(), context = container.mainContext
        let source = MediaSource(name: "Fixture", host: "fixture.invalid", share: "Media", rootPath: "TV", username: "")
        context.insert(source)
        let first = add("TV/24/Season 1/24.S01E01.mp4", source: source, context: context)
        let copy = add("TV/24/Season 1/24.S01E01.4K.mkv", source: source, context: context)
        let second = add("TV/24/Season 1/24.S01E02.mp4", source: source, context: context)
        let otherSeason = add("TV/24/Season 2/24.S02E01.mp4", source: source, context: context)
        first.playbackPosition = 120
        first.lastPlayedAt = Date(timeIntervalSince1970: 20)
        otherSeason.playbackPosition = 300
        try context.save()
        let service = PlaybackServices()
        let show = try XCTUnwrap(TVShowGroup.groups([first, copy, second, otherSeason]).first)
        let result = try BulkWatchStatus.apply(show.episodes(in: 1), watched: true,
            reset: service.resetProgress, save: { try context.save() })
        XCTAssertEqual(result.updatedIDs, [first.id, copy.id, second.id])
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(first.lastPlayedAt, Date(timeIntervalSince1970: 20))
        XCTAssertNil(copy.lastPlayedAt)
        let stored = try ModelContext(container).fetch(FetchDescriptor<Movie>())
        for movie in stored where result.updatedIDs.contains(movie.id) {
            XCTAssertTrue(movie.isWatched)
            XCTAssertEqual(movie.playbackPosition, 0)
        }
        XCTAssertFalse(otherSeason.isWatched)
        XCTAssertEqual(otherSeason.playbackPosition, 300)
        _ = try BulkWatchStatus.apply([first, copy, second], watched: false,
            reset: service.resetProgress, save: { try context.save() })
        XCTAssertTrue([first, copy, second].allSatisfy { !$0.isWatched && $0.playbackPosition == 0 })
    }

    func testFilteredSelectionRechecksSourceRulesAndExcludesPhotosAudioAndHiddenFiles() throws {
        let container = try store(), context = container.mainContext
        let source = MediaSource(name: "Fixture", host: "fixture.invalid", share: "Media", rootPath: "Movies", username: "")
        context.insert(source)
        let chosen = add("Movies/Chosen.mp4", source: source, context: context)
        let ignored = add("Movies/Ignore.mp4", source: source, context: context)
        let hidden = add("Movies/Hidden.mp4", source: source, context: context)
        let outside = add("Archive/Outside.mp4", source: source, context: context)
        let audio = add("Movies/Song.mp3", source: source, context: context)
        let photo = add("Movies/Photo.jpg", source: source, context: context)
        let missing = add("Movies/Missing.mp4", source: source, context: context)
        let unselected = add("Movies/Unselected.mp4", source: source, context: context)
        chosen.genres = ["Drama"]
        unselected.genres = ["Comedy"]
        let selected = LibraryQuery.visible([chosen, unselected], sort: .title, filter: .all, genres: ["Drama"])
        source.ignoredFiles = ["Ignore.mp4"]
        hidden.isHidden = true
        missing.isMissing = true
        let service = PlaybackServices()
        let result = try BulkWatchStatus.apply(selected + [chosen, ignored, hidden, outside, audio, photo, missing],
            watched: true, reset: service.resetProgress, save: { try context.save() })
        XCTAssertEqual(result.updatedIDs, [chosen.id])
        XCTAssertTrue([ignored, hidden, outside, audio, photo, missing, unselected].allSatisfy { !$0.isWatched })
        let explicitHidden = try BulkWatchStatus.apply([hidden, ignored], watched: true, includeHidden: true,
            reset: service.resetProgress, save: { try context.save() })
        XCTAssertEqual(explicitHidden.updatedIDs, [hidden.id])
        XCTAssertTrue(hidden.isHidden)
        XCTAssertFalse(ignored.isWatched)
    }

    func testFailedSaveRestoresOnlyProgressAndReportsResetFailuresSeparately() throws {
        let container = try store(), context = container.mainContext
        let source = MediaSource(name: "Fixture", host: "fixture.invalid", share: "Media", rootPath: "", username: "")
        context.insert(source)
        let first = add("First.mp4", source: source, context: context)
        let second = add("Second.mp4", source: source, context: context)
        first.playbackPosition = 180
        try context.save()
        first.overview = "A pending metadata update"
        let service = PlaybackServices()
        XCTAssertThrowsError(try BulkWatchStatus.apply([first, second], watched: true, reset: service.resetProgress,
            save: { throw NSError(domain: "Fixture save", code: 1) }))
        XCTAssertFalse(first.isWatched)
        XCTAssertFalse(second.isWatched)
        XCTAssertEqual(first.playbackPosition, 180)
        XCTAssertEqual(first.overview, "A pending metadata update")
        let result = try BulkWatchStatus.apply([first, second], watched: true, reset: { movie in
            movie.id == first.id && service.resetProgress(movie)
        }, save: { try context.save() })
        XCTAssertEqual(result.updatedIDs, [first.id])
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertFalse(second.isWatched)
    }

    func testLargeSelectionAndLegacyRowsUseOneSave() throws {
        let container = try store(), context = container.mainContext
        let source = MediaSource(name: "Fixture", host: "fixture.invalid", share: "Media", rootPath: "", username: "")
        context.insert(source)
        let movies = (0..<1_100).map { add("Movie \($0).mp4", source: source, context: context) }
        movies[0].source = nil
        let service = PlaybackServices()
        var saves = 0
        let result = try BulkWatchStatus.apply(movies, watched: true, reset: service.resetProgress, save: {
            saves += 1
            try context.save()
        })
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(result.updatedIDs.count, 1_100)
        XCTAssertTrue(movies.allSatisfy { $0.isWatched && $0.lastPlayedAt == nil })
    }
}
