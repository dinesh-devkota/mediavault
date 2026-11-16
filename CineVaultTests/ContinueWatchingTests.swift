import Foundation
import XCTest
@testable import CineVault

@MainActor
final class ContinueWatchingTests: XCTestCase {
    private let nas = MediaSource(name: "TV fixture", host: "fixture.invalid", share: "Media", rootPath: "", username: "")

    private func file(_ path: String) -> Movie {
        let movie = Movie(filePath: path, fileSize: 120, source: nas)
        movie.resetToFileName()
        return movie
    }

    private func episode(_ number: Int, season: Int = 1, name: String = "24", version: String = "HD.mp4") -> Movie {
        file(String(format: "TV/%@/Season %d/%@.S%02dE%02d.%@", name, season, name, season, number, version))
    }

    private func watched(_ movie: Movie, at time: Double) {
        movie.lastPlayedAt = Date(timeIntervalSince1970: time)
        movie.isWatched = true
    }

    private func partial(_ movie: Movie, at time: Double, position: Double = 120) {
        movie.lastPlayedAt = Date(timeIntervalSince1970: time)
        movie.playbackPosition = position
        movie.duration = 1_000
    }

    func testNewestShowActivityResumesItsExactCopyAlongsidePartialFilms() throws {
        let first = episode(1), current = episode(2), otherCopy = episode(2, version: "4K.mp4")
        let film = file("Movies/A Film.mp4"), finishedFilm = file("Movies/Done.mp4")
        watched(first, at: 100)
        partial(film, at: 200)
        partial(current, at: 300, position: 420)
        watched(finishedFilm, at: 500)
        let input = [first, otherCopy, finishedFilm, film, current]
        let result = ContinueWatching.home(input)
        XCTAssertEqual(result.map(\.movie.id), [current.id, film.id])
        XCTAssertEqual(result.first?.title, "24")
        XCTAssertEqual(result.first?.subtitle, "Resume · S01E02")
        XCTAssertEqual(result.first?.movie.playbackPosition, 420)
        XCTAssertEqual(otherCopy.playbackPosition, 0)
        XCTAssertEqual(ContinueWatching.home(Array(input.reversed()), limit: 1).first?.id, result.first?.id)
    }

    func testLatestCompletedEpisodeAdvancesEvenWithOlderPartialAndIgnoresNewScanDates() {
        let prior = episode(1), finished = episode(2), next = episode(3), film = file("Film.mp4")
        partial(prior, at: 101)
        watched(finished, at: 300)
        partial(film, at: 200)
        next.dateAdded = .distantPast
        let input = [episode(1, name: "New series"), film, prior, next, finished]
        let result = ContinueWatching.home(input)
        XCTAssertEqual(result.map(\.movie.id), [next.id, film.id])
        XCTAssertEqual(result.first?.action, .next)
        XCTAssertEqual(result.first?.lastActivity, finished.lastPlayedAt)
        XCTAssertEqual(ContinueWatching.next(after: finished, in: input)?.movie.id, next.id)
        XCTAssertNil(ContinueWatching.next(after: next, in: input))
    }

    func testMissingExcludedAndUnplayableFilesAreSkippedAndNeverLeakProgressAcrossCopies() {
        let finished = episode(1), hidden = episode(2), outside = episode(3), missing = episode(4)
        let unsupported = episode(5, version: "HD.mkv"), ignored = episode(6), candidate = episode(7)
        let partialCopy = episode(7, version: "alt.mp4")
        nas.rootPath = "TV"
        outside.filePath = outside.filePath.replacingOccurrences(of: "TV/", with: "Archive/", options: .anchored)
        hidden.isHidden = true
        missing.isMissing = true
        nas.ignoredFiles = [String(ignored.filePath.dropFirst("TV/".count))]
        watched(finished, at: 500)
        partial(partialCopy, at: 100, position: 90)
        let library = [finished, hidden, outside, missing, unsupported, ignored, candidate, partialCopy]
        let result = ContinueWatching.home(library).first
        XCTAssertEqual(result?.movie.id, partialCopy.id)
        XCTAssertEqual(result?.subtitle, "Next available · S01E07")
        XCTAssertEqual(candidate.playbackPosition, 0)
        XCTAssertEqual(result?.movie.playbackPosition, 90)
        nas.ignoredFolders = ["24"]
        XCTAssertTrue(ContinueWatching.home(library).isEmpty)
    }

    func testLogicalWatchedSlotsSpecialsFinalesAndRemakes() {
        let last = episode(1), watchedVersion = episode(2), alternate = episode(2, version: "alt.mp4")
        let seasonTwo = episode(1, season: 2), special = episode(1, season: 0), specialTwo = episode(2, season: 0)
        let remake = episode(3)
        for item in [last, watchedVersion, alternate, seasonTwo, special, specialTwo] { item.seriesTMDBID = 11 }
        remake.seriesTMDBID = 22
        watched(last, at: 700)
        watched(watchedVersion, at: 100)
        let items = [remake, alternate, special, last, seasonTwo, specialTwo, watchedVersion]
        XCTAssertEqual(ContinueWatching.home(items).map(\.movie.id), [seasonTwo.id])
        XCTAssertEqual(ContinueWatching.next(after: last, in: items)?.action, .next)
        XCTAssertEqual(ContinueWatching.next(after: special, in: items)?.movie.id, specialTwo.id)
        XCTAssertNil(ContinueWatching.next(after: specialTwo, in: items))
        watched(seasonTwo, at: 900)
        XCTAssertTrue(ContinueWatching.home(items).isEmpty)
    }

    func testUnplayedManualMarksAndShortPlaybackDoNotStartAShow() {
        let manual = episode(1), short = episode(2), next = episode(3), legacy = file("Movies/Partial.mp4")
        manual.isWatched = true
        partial(short, at: 200, position: 30)
        legacy.playbackPosition = 60
        XCTAssertEqual(ContinueWatching.home([manual, short, next, legacy]).map(\.movie.id), [legacy.id])
    }
}
