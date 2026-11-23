package com.dineshdevkota.cinevault.ui

import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.data.SourceEntity
import org.junit.Assert.*
import org.junit.Test

class HomeCollectionsTest {
    private val source = SourceEntity(id = "nas", name = "NAS", host = "nas", share = "Media", rootPath = "Media")
    private fun movie(index: Int) = MovieEntity(id = "film-$index", sourceId = source.id,
        filePath = "Media/Film $index.mp4", fileName = "Film $index.mp4", fileSize = 100,
        parsedTitle = "Film $index", parsedYear = null, title = "Film $index", year = null, addedAt = index.toLong())

    @Test fun seeAllIncludesEveryMovieAndHonorsCurrentSourceRules() {
        val films = (1..25).map(::movie)
        val excluded = source.copy(ignoredFiles = listOf("Film 5.mp4"))
        val extra = listOf(movie(26).copy(isHidden = true), movie(27).copy(isMissing = true),
            movie(28).copy(filePath = "Other/Film 28.mp4"), movie(29).copy(sourceId = "deleted"),
            movie(30).copy(filePath = "Media/Photo.jpg", fileName = "Photo.jpg"))
        val results = homeCollectionItems(HomeCollection.MOVIES, films + extra, listOf(excluded))
        assertEquals(24, results.size)
        assertEquals("movie:film-25", results.first().id)
        assertEquals("movie:film-1", results.last().id)
        assertFalse(results.any { it.id == "movie:film-5" })
        assertTrue(homeCollectionItems(HomeCollection.MOVIES, films, emptyList()).isEmpty())
    }

    @Test fun mixedWatchlistGroupsShowsAndRetainsOnlyMatchingEpisodes() {
        val first = movie(1).copy(filePath = "Media/Show.S01E01.mp4", fileName = "Show.S01E01.mp4",
            seriesTitle = "Show", seriesTmdbId = 24, seasonNumber = 1, episodeNumber = 1, isWatchlisted = true)
        val second = first.copy(id = "episode2", filePath = "Media/Show.S01E02.mp4", episodeNumber = 2)
        val outside = first.copy(id = "episode3", filePath = "Media/Show.S02E01.mp4", seasonNumber = 2, isWatchlisted = false)
        val film = movie(10).copy(isWatchlisted = true, isWatched = true)
        val results = homeCollectionItems(HomeCollection.WATCHLIST, listOf(first, second, outside, film), listOf(source))
        assertEquals(2, results.size)
        assertEquals(setOf(first.id, second.id), results.filterIsInstance<CollectionItem.Show>().single().show.episodes.map { it.id }.toSet())
        assertEquals(film.id, results.filterIsInstance<CollectionItem.Movie>().single().movie.id)
        val unwatched = homeCollectionItems(HomeCollection.UNWATCHED, listOf(first, second, outside, film), listOf(source))
        assertEquals(3, unwatched.filterIsInstance<CollectionItem.Show>().single().show.episodes.size)
        assertTrue(unwatched.none { it is CollectionItem.Movie })
    }

    @Test fun fullContinueWatchingIsUncappedWhileHomeKeepsTwentyCards() {
        val films = (1..25).map { movie(it).copy(playbackPositionMs = 60_000, durationMs = 600_000, lastPlayedAt = it.toLong()) }
        assertEquals(20, continueWatchingItems(films, listOf(source)).size)
        val all = continueWatchingItems(films, listOf(source), limit = Int.MAX_VALUE)
        assertEquals(25, all.size)
        assertEquals("film-25", all.first().movie.id)
        assertEquals("film-1", all.last().movie.id)
    }
}
