package com.dineshdevkota.cinevault.ui

import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.data.SourceEntity
import org.junit.Assert.*
import org.junit.Test

class ContinueWatchingTest {
    private val source = SourceEntity(id = "nas", name = "NAS", host = "nas", share = "Media", rootPath = "Media")
    private val sources = listOf(source)

    private fun movie(path: String) = MovieEntity(id = path, sourceId = source.id, filePath = path,
        fileName = path.substringAfterLast('/'), fileSize = 100, parsedTitle = "Title", parsedYear = null,
        title = "Title", year = null)

    private fun episode(number: Int, season: Int = 1, copy: String = "HD", extension: String = "mkv"): MovieEntity {
        val code = "S${season.toString().padStart(2, '0')}E${number.toString().padStart(2, '0')}"
        return movie("Media/TV/24/Season $season/24.$code.$copy.$extension").copy(
            seriesTitle = "24", seriesTmdbId = 24, seasonNumber = season, episodeNumber = number, title = "Hour $number",
        )
    }

    private fun MovieEntity.finished(at: Long?) = copy(isWatched = true, lastPlayedAt = at)
    private fun MovieEntity.paused(at: Long?, position: Long = 80_000) = copy(playbackPositionMs = position, lastPlayedAt = at)

    @Test fun resumesLatestMeaningfulFileOncePerSeriesAndRanksByActualActivity() {
        val latest = episode(2, copy = "SD").paused(30, 49_000)
        val film = movie("Media/Film.mp4").paused(40)
        val oldFilm = movie("Media/Classic.mp4").paused(null)
        val items = listOf(episode(1).paused(10), episode(2), latest, episode(3).paused(100, 30_000),
            episode(4).copy(addedAt = 500), film, oldFilm, movie("Media/Finished.mp4").finished(60),
            movie("Media/Song.mp3").paused(70), movie("Media/Picture.jpg").paused(80))
        val cards = continueWatchingItems(items, sources)
        assertEquals(listOf(film.id, latest.id, oldFilm.id), cards.map { it.movie.id })
        assertEquals("show:tmdb:24", cards[1].id)
        assertEquals("Resume · S01E02", cards[1].label)
        assertEquals(49_000L, cards[1].movie.playbackPositionMs)
        assertEquals(cards, continueWatchingItems(items.reversed(), sources))
    }

    @Test fun nextSkipsWatchedCopiesAndKeepsProgressOnItsOriginalFile() {
        val anchor = episode(1).finished(500)
        val partiallyPlayed = episode(3, copy = "SD").paused(200, 72_000)
        val library = listOf(anchor, episode(2), episode(2, copy = "SD").finished(100),
            episode(3), partiallyPlayed, episode(4))
        val next = continueWatchingItems(library, sources).single()
        assertEquals("Next available · S01E03", next.label)
        assertEquals(partiallyPlayed, next.movie)
        assertEquals(500L, next.activityAt)
        assertEquals(next, nextEpisodeFor(anchor, library, sources))
        assertEquals(next, continueWatchingItems(library.reversed(), sources).single())
    }

    @Test fun skipsUnavailableSourcesPathsAndFilesBeforePickingADestination() {
        val anchor = episode(1).finished(100)
        val ignoredFolder = episode(4).copy(filePath = "Media/Excluded/item.mp4")
        val ignoredFile = episode(5)
        val excluded = source.copy(ignoredFolders = listOf("Excluded"), ignoredFiles = listOf(ignoredFile.filePath.removePrefix("Media/")))
        val target = episode(9)
        val library = listOf(anchor, episode(2).copy(isHidden = true), episode(3).copy(isMissing = true),
            ignoredFolder, ignoredFile, episode(6).copy(filePath = "Other/something.mp4"),
            episode(7, extension = "iso"), episode(8).copy(sourceId = "removed"), target)
        assertEquals(target, continueWatchingItems(library, listOf(excluded)).single().movie)
        assertEquals(ContinueAction.NEXT_AVAILABLE, nextEpisodeFor(anchor, library, listOf(excluded))?.action)
        assertTrue(continueWatchingItems(library, emptyList()).isEmpty())
        assertNull(nextEpisodeFor(ignoredFile, library, listOf(excluded)))
    }

    @Test fun specialsAndFinalesStopWithinTheirOwnSequence() {
        val special = episode(1, season = 0).finished(100)
        val start = episode(1)
        val nextSeason = episode(1, season = 2)
        assertNull(nextEpisodeFor(special, listOf(special, start), sources))
        assertTrue(continueWatchingItems(listOf(special, start), sources).isEmpty())
        assertEquals("Next episode · S00E02", nextEpisodeFor(special, listOf(special, episode(2, season = 0), start), sources)?.label)
        val finale = episode(24).finished(200)
        assertEquals("Next episode · S02E01", nextEpisodeFor(finale, listOf(finale, nextSeason), sources)?.label)
        assertEquals("Next available · S03E01", nextEpisodeFor(finale, listOf(finale, episode(1, season = 3)), sources)?.label)
        assertTrue(continueWatchingItems(listOf(special, start, finale), sources).isEmpty())
    }

    @Test fun localAndMatchedEpisodesGroupWithoutMixingRemakesOrStartingUnplayedSeries() {
        val anchor = episode(1).finished(50)
        val local = episode(2).copy(seriesTmdbId = null, seriesTitle = null)
        val remake = episode(2).copy(id = "remake", filePath = "Media/New/2024/Remake.S01E02.mp4",
            seriesTitle = "24", seriesTmdbId = 99)
        assertEquals(local.id, continueWatchingItems(listOf(anchor, local), sources).single().movie.id)
        assertNull(nextEpisodeFor(anchor, listOf(anchor, remake), sources))
        val undated = anchor.finished(null)
        assertTrue(continueWatchingItems(listOf(undated, local, remake), sources).isEmpty())
        assertEquals("Next episode · S01E02", nextEpisodeFor(undated, listOf(undated, local), sources)?.label)
    }
}
