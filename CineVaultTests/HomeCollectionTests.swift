import Foundation
import XCTest
@testable import CineVault

@MainActor
final class HomeCollectionTests: XCTestCase {
    private let nas = MediaSource(name: "Fixture", host: "fixture.invalid", share: "Media", rootPath: "", username: "")

    private func file(_ path: String) -> Movie {
        let movie = Movie(filePath: path, fileSize: 100, source: nas)
        movie.resetToFileName()
        return movie
    }

    func testSeeAllIncludesTitlesBeyondHomeLimitAndGroupsCompleteSeasons() throws {
        let films = (1...25).map { number -> Movie in
            let movie = file("Movies/Film \(number).mp4")
            movie.dateAdded = Date(timeIntervalSince1970: Double(100 - number))
            movie.isWatchlisted = true
            return movie
        }
        let episodes = (1...2).flatMap { season in
            (1...12).map { number -> Movie in
                let movie = file(String(format: "TV Shows/24/Season %d/24.S%02dE%02d.mp4", season, season, number))
                movie.isWatchlisted = true
                return movie
            }
        }
        let library = films + episodes
        XCTAssertEqual(CollectionRowItem.grouped(HomeCollection.watchlist.movies(in: library)).count, 20)
        XCTAssertEqual(HomeCollection.section(.movie).items(in: library).count, 25)
        XCTAssertEqual(HomeCollection.watchlist.items(in: library).count, 26)
        let shows = HomeCollection.section(.tvShow).items(in: library)
        XCTAssertEqual(shows.count, 1)
        guard case .show(let show) = try XCTUnwrap(shows.first) else { return XCTFail("Episodes should be grouped.") }
        XCTAssertEqual(show.seasons, [1, 2])
        XCTAssertEqual(show.episodes(in: 2).count, 12)
        XCTAssertEqual(HomeCollection.section(.movie).movies(in: library).last?.id, films.last?.id)
    }

    func testCurrentVisibilityAndSourceRulesApplyWithoutAnotherScan() {
        nas.rootPath = "Media"
        let visible = file("Media/Movies/Visible.mp4")
        let hidden = file("Media/Movies/Hidden.mp4"); hidden.isHidden = true
        let missing = file("Media/Movies/Missing.mp4"); missing.isMissing = true
        let outside = file("Archive/Outside.mp4")
        let ignored = file("Media/Private/Ignore.mp4")
        let ignoredFile = file("Media/Movies/Ignore.mp4")
        let orphan = file("Media/Movies/Removed.mp4"); orphan.source = nil
        let photo = file("Media/Photos/Photo.jpg")
        let library = [visible, hidden, missing, outside, ignored, ignoredFile, orphan, photo]
        library.forEach { $0.isWatchlisted = true }
        nas.ignoredFolders = ["Private"]
        nas.ignoredFiles = ["Movies/Ignore.mp4"]
        XCTAssertEqual(HomeCollection.watchlist.movies(in: library).map(\.id), [visible.id])
        XCTAssertEqual(HomeCollection.unwatched.movies(in: library).map(\.id), [visible.id])
        visible.isWatched = true
        XCTAssertTrue(HomeCollection.unwatched.movies(in: library).isEmpty)
        visible.source = nil
        XCTAssertTrue(HomeCollection.watchlist.movies(in: library).isEmpty)
    }

    func testContinueWatchingSeeAllKeepsMoreThanTwentyResumableTitles() {
        let films = (1...25).map { number -> Movie in
            let movie = file("Movies/Film \(number).mp4")
            movie.playbackPosition = 120
            movie.duration = 1_000
            movie.lastPlayedAt = Date(timeIntervalSince1970: Double(number))
            return movie
        }
        XCTAssertEqual(ContinueWatching.home(films).count, 20)
        XCTAssertEqual(HomeCollection.continueWatching.movies(in: films).count, 25)
        XCTAssertEqual(HomeCollection.continueWatching.movies(in: films).first?.id, films.last?.id)
    }

    func testHomeBrowsingIgnoresAndPreservesSavedLibraryFilters() throws {
        let suite = "home-collection-preferences-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = LibraryPreferences(defaults: defaults)
        preferences.section = .music
        preferences.filter = .watched
        preferences.genres = ["Unmatched genre"]
        preferences.decades = [1980]
        preferences.sourceIDs = [UUID()]
        let expectedSources = preferences.sourceIDs
        let movie = file("Movies/Film.mp4")
        XCTAssertEqual(HomeCollection.section(.movie).movies(in: [movie]).map(\.id), [movie.id])
        let restored = LibraryPreferences(defaults: defaults)
        XCTAssertEqual(restored.section, .music)
        XCTAssertEqual(restored.filter, .watched)
        XCTAssertEqual(restored.genres, ["Unmatched genre"])
        XCTAssertEqual(restored.decades, [1980])
        XCTAssertEqual(restored.sourceIDs, expectedSources)
    }
}
