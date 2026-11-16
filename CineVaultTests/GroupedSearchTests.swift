import CineVaultCore
import Foundation
import XCTest
@testable import CineVault

@MainActor
final class GroupedSearchTests: XCTestCase {
    private func source() -> MediaSource { MediaSource(name: "NAS", host: "fixture.invalid", share: "Media", rootPath: "", username: "") }
    private func episode(_ path: String, title: String? = nil, source: MediaSource? = nil) -> Movie {
        let item = Movie(filePath: path, fileSize: 10, source: source ?? self.source())
        item.resetToFileName()
        if let title { item.setTitle(title) }
        return item
    }
    private func show(_ name: String = "24", seasons: Int = 1, episodes: Int = 4) -> [Movie] {
        let source = source()
        return (1...seasons).flatMap { season in
            (1...episodes).map { episode("TV/\(name)/Season \(season)/\(name).S\(String(format: "%02d", season))E\(String(format: "%02d", $0)).1080p.mp4",
                title: "Day \(season) · Hour \($0)", source: source) }
        }
    }

    func testSeriesSearchProducesOneMasterAndKeepsAllEightSeasons() throws {
        let episodes = show(seasons: 8, episodes: 24)
        let result = LibrarySearch.results(in: episodes, text: "24")
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result.episodes.isEmpty)
        let hit = try XCTUnwrap(result.shows.first)
        XCTAssertEqual(hit.show.episodes.count, 192)
        XCTAssertEqual(hit.show.seasons, Array(1...8))
        XCTAssertEqual(hit.subtitle, "8 seasons · 192 episodes")
        XCTAssertEqual(LibrarySearch.results(in: Array(episodes.reversed()), text: "24").shows.first?.id, hit.id)
    }

    func testShowEntryFocusStartsWithTheFirstAvailableEpisodeInReverseScanOrder() throws {
        let episodes = show(seasons: 2, episodes: 3)
        let reversed = Array(episodes.reversed())
        let group = try XCTUnwrap(TVShowGroup.groups(reversed).first)
        XCTAssertEqual(group.firstEpisode?.id, episodes[0].id)
        XCTAssertEqual(group.episodes(in: 2).first?.id, episodes[3].id)
    }

    func testCanonicalAndLocalSeriesNamesFindOneFullPartiallyMatchedShow() throws {
        let episodes = show("Local Name", episodes: 3)
        episodes[0].seriesTitle = "Canonical Title"; episodes[0].seriesTMDBID = 42
        for query in ["canonical title", " LOCAL NAME "] {
            let result = LibrarySearch.results(in: episodes, text: query)
            XCTAssertEqual(result.shows.count, 1)
            XCTAssertEqual(result.shows.first?.id, "tmdb:42")
            XCTAssertEqual(result.shows.first?.show.episodes.count, 3)
            XCTAssertTrue(result.episodes.isEmpty)
        }
        episodes[0].genres = ["  Dráma  "]
        XCTAssertEqual(LibrarySearch.results(in: episodes, text: " drama ").shows.first?.show.episodes.count, 3)
    }

    func testEpisodeTitleFilenameAndCombinedSeriesCodeRemainDirect() throws {
        let source = source()
        let pilot = episode("TV/Example/Season 1/S01E01.mp4", title: "Pilot", source: source)
        let second = episode("TV/Example/Season 1/S01E02.mp4", title: "The Return", source: source)
        for query in ["Pilot", "S01E01.mp4", "Example S1E1"] {
            let result = LibrarySearch.results(in: [pilot, second], text: query)
            XCTAssertTrue(result.shows.isEmpty, query)
            XCTAssertEqual(result.episodes.map(\.movie.id), [pilot.id], query)
        }
        XCTAssertEqual(LibrarySearch.results(in: [pilot, second], text: "Example The Return").episodes.first?.movie.id, second.id)
    }

    func testBroadEpisodeMatchesCollapseAndCountLogicalEpisodesNotEncodes() throws {
        let episodes = show(episodes: 4)
        let duplicate = episode("TV/24/Season 1/24.S01E01.720p.mp4", title: episodes[0].title, source: episodes[0].source)
        let result = LibrarySearch.results(in: episodes + [duplicate], text: "Day")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.shows.first?.matchingEpisodeCount, 4)
        XCTAssertEqual(result.shows.first?.subtitle, "4 matching episodes")
        XCTAssertEqual(result.shows.first?.show.episodes.count, 5, "The destination retains alternate files and complete available seasons.")
        let direct = LibrarySearch.results(in: Array(episodes.prefix(3)) + [duplicate], text: "Day")
        XCTAssertTrue(direct.shows.isEmpty)
        XCTAssertEqual(direct.episodes.count, 3)
        XCTAssertEqual(Set(direct.episodes.map(\.id)).count, 3)
        XCTAssertEqual(LibrarySearch.results(in: episodes + [duplicate], text: "24.S01E01.720p.mp4").episodes.first?.movie.id, duplicate.id)
    }

    func testRemakeYearQueryDoesNotConfuseNumericShowTitleWithReleaseYear() throws {
        let original = show("Example (1990)", episodes: 2)
        let remake = show("Example (2024)", episodes: 2)
        XCTAssertEqual(LibrarySearch.results(in: original + remake, text: "Example").shows.count, 2)
        let originalHit = LibrarySearch.results(in: original + remake, text: "Example (1990)")
        XCTAssertEqual(originalHit.shows.count, 1)
        XCTAssertEqual(Set(originalHit.shows[0].show.episodes.map(\.id)), Set(original.map(\.id)))
        XCTAssertTrue(LibrarySearch.results(in: original + remake, text: "24").isEmpty)
        let numeric = show("24", episodes: 2)
        XCTAssertEqual(LibrarySearch.results(in: original + remake + numeric, text: "24").shows.count, 1)
    }

    func testNumericSearchUsesWholeNumbersInMovieAndPhotoTitlesFilesAndGenres() {
        let nas = source()
        let movie = episode("Movies/Feature.mp4", title: "24 Hour Party People", source: nas)
        let photo = episode("Photos/IMG-24.jpg", title: "Camping", source: nas)
        let genre = episode("Movies/Portrait.mp4", source: nas)
        genre.genres = ["24 FPS"]
        let recentMovie = episode("Movies/Orbit (2024).mp4", title: "Orbit", source: nas)
        let recentPhoto = episode("Photos/IMG-2024.jpg", title: "Summer 2024", source: nas)
        let recentGenre = episode("Music/Track.flac", source: nas)
        recentGenre.genres = ["Hits of 2024"]
        let result = LibrarySearch.results(in: [movie, photo, genre, recentMovie, recentPhoto, recentGenre], text: "24")
        XCTAssertEqual(Set(result.titles.map(\.id)), [movie.id, genre.id])
        XCTAssertEqual(result.photos.map(\.id), [photo.id])
    }

    func testHiddenMissingIgnoredAndOldRootEpisodesNeverLeakThroughFullShow() throws {
        let episodes = show(episodes: 4)
        episodes[1].isHidden = true; episodes[2].isMissing = true
        episodes[3].source?.ignoredFiles = [episodes[3].filePath]
        let result = LibrarySearch.results(in: episodes, text: "24")
        XCTAssertEqual(result.shows.first?.show.episodes.map(\.id), [episodes[0].id])
        episodes[0].source?.rootPath = "Other"
        XCTAssertTrue(LibrarySearch.results(in: episodes, text: "24").isEmpty)
    }

    func testMoviesAndPhotosRemainSeparateAndPunctuationDoesNotMatchEverything() throws {
        let source = source()
        let movie = episode("Movies/A Trip.mp4", title: "A Trip", source: source)
        let photo = episode("Photos/A Trip.jpg", source: source)
        let unavailable = episode("Other/A Trip.jpg", source: self.source()); unavailable.source?.rootPath = "Photos"
        let result = LibrarySearch.results(in: [movie, photo, unavailable], text: "Trip")
        XCTAssertEqual(result.titles.map(\.id), [movie.id])
        XCTAssertEqual(result.photos.map(\.id), [photo.id])
        XCTAssertEqual(result.count, 2)
        for query in ["", "   ", "...", "[]"] { XCTAssertTrue(LibrarySearch.results(in: show(), text: query).isEmpty) }
    }

    func testSourceEditsImmediatelyExcludeMoviesAndMusicFromSearch() {
        let nas = source()
        let visible = episode("Media/Movies/River.mp4", source: nas)
        let ignoredFile = episode("Media/Movies/River II.mp4", source: nas)
        let ignoredFolder = episode("Media/Private/River.flac", source: nas)
        let oldRoot = episode("Old/River.mp4", source: nas)
        let items = [visible, ignoredFile, ignoredFolder, oldRoot]
        XCTAssertEqual(LibrarySearch.results(in: items, text: "River").titles.count, 4)
        nas.rootPath = "Media"
        nas.ignoredFiles = ["Movies/River II.mp4"]
        nas.ignoredFolders = ["Private"]
        XCTAssertEqual(LibrarySearch.results(in: items, text: "River").titles.map(\.id), [visible.id])
    }

    func testFocusAnchorFollowsTheSameShowWhenMetadataChangesItsGroupID() throws {
        let episodes = show("Local Name", episodes: 2)
        let local = LibrarySearch.results(in: episodes, text: "Local Name")
        let oldFocus = "show:\(try XCTUnwrap(local.shows.first).id)"
        let anchor = try XCTUnwrap(local.movieID(forFocusID: oldFocus))
        episodes[0].seriesTitle = "Canonical Title"; episodes[0].seriesTMDBID = 42
        let matched = LibrarySearch.results(in: episodes, text: "Local Name")
        XCTAssertFalse(matched.focusIDs.contains(oldFocus))
        XCTAssertEqual(matched.focusID(containing: anchor), "show:tmdb:42")
    }

    func testOpenSearchShowTracksLibraryAndSourceEditsUntilNoEligibleEpisodesRemain() throws {
        let original = show("Local Name", episodes: 2)
        let nas = try XCTUnwrap(original[0].source)
        let hit = try XCTUnwrap(LibrarySearch.results(in: original, text: "Local Name").shows.first)
        let selection = SearchShowSelection(hit.show)
        let added = episode("TV/Local Name/Season 2/Local Name.S02E01.mp4", source: nas)
        let library = original + [added] + show("Other Show", episodes: 1)

        nas.ignoredFiles = [original[0].filePath]
        original[1].seriesTitle = "Canonical Name"
        original[1].seriesTMDBID = 42
        let current = try XCTUnwrap(selection.resolve(in: library))
        XCTAssertEqual(current.id, "tmdb:42")
        XCTAssertEqual(Set(current.episodes.map(\.id)), [original[1].id, added.id])

        original[1].isMissing = true
        added.seriesTMDBID = 42
        XCTAssertEqual(selection.resolve(in: library, currentShowID: current.id)?.episodes.map(\.id), [added.id])
        nas.rootPath = "Photos"
        XCTAssertNil(selection.resolve(in: library, currentShowID: current.id))
    }
}
