import CineVaultCore
import Foundation
import SwiftData
import XCTest
@testable import CineVault

@MainActor
final class ContentRatingMetadataTests: XCTestCase {
    private func movie(_ path: String = "Movies/Example.mp4", id: Int? = 42) -> Movie {
        let source = MediaSource(name: "Fixture", host: "fixture.invalid", share: "Media", rootPath: "", username: "")
        let movie = Movie(filePath: path, fileSize: 1, source: source)
        movie.resetToFileName()
        movie.tmdbID = id
        movie.metadataFetched = true
        return movie
    }

    private func response(_ request: URLRequest, json: String, status: Int = 200) throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(request.url)
        return (Data(json.utf8), try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
    }

    func testDetailsStoreContentCertificationSeparatelyFromAudienceScore() async throws {
        let movie = movie()
        let service = MetadataService(requestData: { request in
            try self.response(request, json: #"{"id":42,"title":"Example","vote_average":8.8,"release_dates":{"results":[{"iso_3166_1":"US","release_dates":[{"certification":"PG"},{"certification":"R"}]}]}}"#)
        }, readAPIKey: { "fixture" })
        _ = try await service.apply(tmdbID: 42, to: movie)
        XCTAssertEqual(movie.rating, 8.8)
        XCTAssertEqual(movie.usContentRating, "R")
        XCTAssertEqual(movie.usContentRatingFetched, true)
        service.resetToFileName(movie)
        XCTAssertNil(movie.usContentRating)
        XCTAssertNil(movie.usContentRatingFetched)
    }

    func testRematchWithAbsentCertificationClearsOldCertificationAndRemainsRetryable() async throws {
        let movie = movie()
        movie.usContentRating = "G"; movie.usContentRatingFetched = true
        let service = MetadataService(requestData: { request in
            try self.response(request, json: #"{"id":43,"title":"Different movie","vote_average":9.9}"#)
        }, readAPIKey: { "fixture" })
        _ = try await service.apply(tmdbID: 43, to: movie, force: true)
        XCTAssertEqual(movie.tmdbID, 43)
        XCTAssertNil(movie.usContentRating)
        XCTAssertEqual(movie.usContentRatingFetched, false)
    }

    func testPlexServerCertificationSurvivesUnmatchedMovieAndShowSearches() async throws {
        let film = movie("PlexVideo/101.mp4", id: nil)
        let episode = movie("PlexVideo/203.mp4", id: nil)
        episode.seriesTitle = "Fixture Show"
        episode.seasonNumber = 1
        episode.episodeNumber = 2
        for item in [film, episode] {
            let source = try XCTUnwrap(item.source)
            source.sourceProtocol = "plex"
            item.usContentRating = "R"
            item.usContentRatingFetched = true
            let service = MetadataService(requestData: { request in
                try self.response(request, json: #"{"results":[]}"#)
            }, readAPIKey: { "fixture" })
            try await service.match(item)
            XCTAssertEqual(item.usContentRating, "R")
            XCTAssertEqual(item.usContentRatingFetched, true)
        }
    }

    func testPlexServerCertificationSurvivesOnlineRematchAndBackfill() async throws {
        let film = movie("PlexVideo/101.mp4")
        let source = try XCTUnwrap(film.source)
        source.sourceProtocol = "plex"
        film.usContentRating = "R"
        film.usContentRatingFetched = true
        var requests = 0
        let service = MetadataService(requestData: { request in
            requests += 1
            return try self.response(request, json: #"{"id":42,"title":"Example","release_dates":{"results":[{"iso_3166_1":"US","release_dates":[{"certification":"G"}]}]}}"#)
        }, readAPIKey: { "fixture" })
        _ = try await service.apply(tmdbID: 42, to: film, force: true)
        try await service.fetchUSContentRating(for: film)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(film.usContentRating, "R")
        XCTAssertEqual(film.usContentRatingFetched, true)
    }

    func testPlexFilenameResetCannotEraseServerRatingOrEpisodeIdentity() throws {
        let episode = movie("PlexVideo/203.mp4")
        let source = try XCTUnwrap(episode.source)
        source.sourceProtocol = "plex"
        episode.fileName = "Server Episode"
        episode.parsedTitle = "Server Episode"
        episode.setTitle("My episode title")
        episode.isLocked = true
        episode.seriesTitle = "Fixture Show"
        episode.providerSeriesID = "201"
        episode.seriesTMDBID = 7
        episode.seasonNumber = 1
        episode.episodeNumber = 2
        episode.usContentRating = "TV-MA"
        episode.usContentRatingFetched = true
        episode.overview = "Server episode description"
        episode.providerImageTag = "/library/metadata/203/thumb"
        episode.playbackPosition = 75
        let originalSeriesKey = episode.seriesKey

        MetadataService().resetToFileName(episode)

        XCTAssertEqual(episode.title, "My episode title")
        XCTAssertEqual(episode.parsedTitle, "Server Episode")
        XCTAssertTrue(episode.isLocked)
        XCTAssertEqual(episode.tmdbID, 42)
        XCTAssertEqual(episode.seriesTMDBID, 7)
        XCTAssertEqual(episode.seriesKey, originalSeriesKey)
        XCTAssertEqual(episode.episodeInfo?.seriesTitle, "Fixture Show")
        XCTAssertEqual(episode.episodeInfo?.season, 1)
        XCTAssertEqual(episode.episodeInfo?.episode, 2)
        XCTAssertEqual(episode.usContentRating, "TV-MA")
        XCTAssertEqual(episode.usContentRatingFetched, true)
        XCTAssertEqual(episode.overview, "Server episode description")
        XCTAssertEqual(episode.providerImageTag, "/library/metadata/203/thumb")
        XCTAssertEqual(episode.playbackPosition, 75)
        XCTAssertTrue(episode.metadataFetched)
    }

    func testFetchMissingBackfillsOldLockedMovieWithoutReplacingLibraryState() async throws {
        let container = try ModelContainer(for: MediaSource.self, Movie.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let movie = movie()
        container.mainContext.insert(try XCTUnwrap(movie.source)); container.mainContext.insert(movie)
        movie.setTitle("My title"); movie.posterPath = "/my-poster.jpg"; movie.isLocked = true
        movie.playbackPosition = 345; movie.isWatchlisted = true; movie.rating = 8.8
        var paths: [String] = []
        let service = MetadataService(requestData: { request in
            paths.append(try XCTUnwrap(request.url).path)
            return try self.response(request, json: #"{"results":[{"iso_3166_1":"US","release_dates":[{"certification":"PG-13"}]}]}"#)
        }, readAPIKey: { "fixture" })
        let result = try await service.fetchMissing(in: container.mainContext)
        XCTAssertEqual(result?.attempted, 1); XCTAssertEqual(result?.failed, 0)
        XCTAssertEqual(paths, ["/3/movie/42/release_dates"])
        XCTAssertEqual(movie.usContentRating, "PG-13")
        XCTAssertEqual(movie.usContentRatingFetched, true)
        XCTAssertEqual(movie.title, "My title"); XCTAssertEqual(movie.posterPath, "/my-poster.jpg")
        XCTAssertTrue(movie.isLocked); XCTAssertTrue(movie.isWatchlisted)
        XCTAssertEqual(movie.playbackPosition, 345); XCTAssertEqual(movie.rating, 8.8)
        let repeated = try await service.fetchMissing(in: container.mainContext)
        XCTAssertEqual(repeated?.attempted, 0)
    }

    func testSuccessfulEmptyIsRememberedButMalformedAndFailedLookupsCanRetry() async throws {
        let container = try ModelContainer(for: MediaSource.self, Movie.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let movie = movie()
        container.mainContext.insert(try XCTUnwrap(movie.source)); container.mainContext.insert(movie)
        var calls = 0
        let service = MetadataService(requestData: { request in
            calls += 1
            if calls == 1 { return try self.response(request, json: "{}", status: 503) }
            if calls == 2 { return try self.response(request, json: #"{"status_code":34}"#) }
            return try self.response(request, json: #"{"results":[]}"#)
        }, readAPIKey: { "fixture" })
        for _ in 0..<2 {
            let result = try await service.fetchMissing(in: container.mainContext)
            XCTAssertEqual(result?.failed, 1)
            XCTAssertNil(movie.usContentRatingFetched)
        }
        let succeeded = try await service.fetchMissing(in: container.mainContext)
        XCTAssertEqual(succeeded?.failed, 0)
        XCTAssertEqual(movie.usContentRatingFetched, true); XCTAssertNil(movie.usContentRating)
        let repeated = try await service.fetchMissing(in: container.mainContext)
        XCTAssertEqual(repeated?.attempted, 0); XCTAssertEqual(calls, 3)
    }

    func testTVBackfillUsesSeriesRatingAndCachesSuccessfulEmptyResults() async throws {
        let first = movie("TV Shows/Example/Season 1/Example.S01E01.mp4", id: nil)
        let second = movie("TV Shows/Example/Season 1/Example.S01E02.mp4", id: nil)
        first.seriesTMDBID = 7; second.seriesTMDBID = 7
        var paths: [String] = []
        let service = MetadataService(requestData: { request in
            paths.append(try XCTUnwrap(request.url).path)
            return try self.response(request, json: #"{"results":[]}"#)
        }, readAPIKey: { "fixture" })
        try await service.fetchUSContentRating(for: first)
        try await service.fetchUSContentRating(for: second)
        XCTAssertEqual(paths, ["/3/tv/7/content_ratings"])
        XCTAssertEqual(first.usContentRatingFetched, true); XCTAssertEqual(second.usContentRatingFetched, true)
        XCTAssertNil(first.usContentRating); XCTAssertNil(second.usContentRating)
    }

    func testNoKeyOrUnmatchedMediaDoesNotClaimCertificationWasFetched() async throws {
        let movie = movie()
        let service = MetadataService(requestData: { _ in
            XCTFail("No request should run without a key."); throw URLError(.unsupportedURL)
        }, readAPIKey: { "" })
        try await service.fetchUSContentRating(for: movie)
        XCTAssertNil(movie.usContentRatingFetched)
        let unmatched = self.movie(id: nil)
        let keyed = MetadataService(requestData: { _ in
            XCTFail("An unmatched item has no certification endpoint."); throw URLError(.unsupportedURL)
        }, readAPIKey: { "fixture" })
        try await keyed.fetchUSContentRating(for: unmatched)
        XCTAssertNil(unmatched.usContentRatingFetched)
    }

    func testLateBackfillCannotOverrideRematchResetOrRemovedSource() async throws {
        for change in 0..<4 {
            let movie = movie()
            var service: MetadataService!
            service = MetadataService(requestData: { request in
                switch change {
                case 0: movie.tmdbID = 99; movie.usContentRating = "R"; movie.usContentRatingFetched = true
                case 1: service.resetToFileName(movie)
                case 2: movie.source = nil
                default: movie.seriesTMDBID = 7
                }
                return try self.response(request, json: #"{"results":[{"iso_3166_1":"US","release_dates":[{"certification":"G"}]}]}"#)
            }, readAPIKey: { "fixture" })
            try await service.fetchUSContentRating(for: movie)
            if change == 0 { XCTAssertEqual(movie.usContentRating, "R") }
            else { XCTAssertNil(movie.usContentRating); XCTAssertNil(movie.usContentRatingFetched) }
        }
    }

    func testManualChangesRequireAdminAndLateResponseCannotCrossHouseholdSessions() async throws {
        let suite = "ContentRatingMetadataTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let household = HouseholdStore(defaults: defaults, read: { nil }, write: { _ in }, erase: {})
        try household.setup(pin: "123456", confirmation: "123456")
        let admin = try XCTUnwrap(household.profiles.first(where: \.isAdmin))
        let movie = movie()
        movie.usContentRating = "R"; movie.usContentRatingFetched = true
        var requests = 0
        let service = MetadataService(requestData: { request in
            requests += 1
            household.lock()
            try household.unlock(admin.id, pin: "123456")
            return try self.response(request, json: #"{"id":43,"title":"Different","release_dates":{"results":[{"iso_3166_1":"US","release_dates":[{"certification":"G"}]}]}}"#)
        }, readAPIKey: { "fixture" }, household: household)
        service.resetToFileName(movie)
        XCTAssertEqual(movie.usContentRating, "R")
        XCTAssertThrowsError(try service.setAPIKey("fixture"))
        let denied = try await service.apply(tmdbID: 43, to: movie, force: true)
        XCTAssertFalse(denied); XCTAssertEqual(requests, 0)
        try household.unlock(admin.id, pin: "123456")
        let stale = try await service.apply(tmdbID: 43, to: movie, force: true)
        XCTAssertFalse(stale); XCTAssertEqual(requests, 1)
        XCTAssertEqual(movie.tmdbID, 42); XCTAssertEqual(movie.usContentRating, "R")
    }

    func testCancelledBackfillDoesNotMarkLookupCompleted() async throws {
        let movie = movie()
        var cancellation: (() -> Void)?
        let service = MetadataService(requestData: { request in
            cancellation?()
            return try self.response(request, json: #"{"results":[]}"#)
        }, readAPIKey: { "fixture" })
        let task = Task { try await service.fetchUSContentRating(for: movie) }
        cancellation = { task.cancel() }
        do { try await task.value; XCTFail("Cancellation must propagate.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(movie.usContentRatingFetched)
        XCTAssertNil(movie.usContentRating)
    }
}
