package com.dineshdevkota.cinevault.library

import com.dineshdevkota.cinevault.data.MovieEntity
import org.junit.Assert.*
import org.junit.Test

class MediaCollectionsTest {
    private fun movie(id: String, title: String = "Feature", year: Int? = 2020, tmdb: Int? = null) =
        MovieEntity(id = id, sourceId = "nas", filePath = "$id.mp4", fileName = "$id.mp4", fileSize = 100,
            parsedTitle = title, parsedYear = year, title = title, year = year, tmdbId = tmdb)
    @Test fun stableMetadataIdsGroupDifferentCutsWithoutCombiningRemakes() {
        val groups = groupMovieVersions(listOf(movie("one", tmdb = 10), movie("two", "Director's cut", tmdb = 10), movie("remake", tmdb = 20)))
        assertEquals(listOf(2, 1), groups.map { it.versions.size })
    }
    @Test fun fallbackNeedsExactTitleAndKnownYear() {
        assertEquals(1, groupMovieVersions(listOf(movie("one"), movie("two", "FEATURE"))).size)
        assertEquals(2, groupMovieVersions(listOf(movie("one", year = null), movie("two", year = null))).size)
        assertEquals(2, groupMovieVersions(listOf(movie("one"), movie("two", year = 2021))).size)
    }
    @Test fun episodesNeverCollapseAsAlternateMovieVersions() {
        val one = movie("one").copy(filePath = "Show S01E01.mp4")
        val two = one.copy(id = "two", filePath = "Show S01E02.mp4")
        assertEquals(2, groupMovieVersions(listOf(one, two)).size)
    }
    @Test fun groupingPreservesSortAndIndividualHistory() {
        val first = movie("one").copy(playbackPositionMs = 1000)
        val second = movie("two").copy(isWatched = true)
        val group = groupMovieVersions(listOf(first, second)).single()
        assertEquals(first, group.representative)
        assertEquals(1000L, group.versions[0].playbackPositionMs); assertTrue(group.versions[1].isWatched)
    }
}
