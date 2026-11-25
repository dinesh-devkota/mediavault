package com.dineshdevkota.cinevault.jellyfin

import com.dineshdevkota.cinevault.family.FamilyPolicy
import com.dineshdevkota.cinevault.family.FolderAccess
import com.dineshdevkota.cinevault.family.HouseholdProfile
import com.dineshdevkota.cinevault.subtitles.SubDlMediaType
import com.dineshdevkota.cinevault.subtitles.SubDlSearchQuery
import com.dineshdevkota.cinevault.subtitles.subtitleQuery
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class JellyfinLibraryTest {
    @Test fun importedEpisodeIsHiddenUntilTheLibraryIsGrantedAndUsesSeriesRating() {
        val item = JellyfinItem("ep1", "Episode One", "Episode", seriesId = "series1",
            seriesName = "Series", seasonNumber = 1, indexNumber = 1, rating = "TV-Y")
        val series = JellyfinItem("series1", "Series", "Series", rating = "TV-MA")
        val movie = requireNotNull(jellyfinMovie("source1", item, series))
        val viewer = HouseholdProfile("viewer", "Viewer")
        assertEquals("ep1", jellyfinItemID(movie.filePath))
        assertEquals("TV-MA", movie.ageCertification)
        assertFalse(FamilyPolicy.allows(viewer, movie))
        val granted = viewer.copy(folders = listOf(FolderAccess("source1", "", caseSensitive = true)))
        assertFalse(FamilyPolicy.allows(granted.copy(tvLimit = "TV-14"), movie))
        assertTrue(FamilyPolicy.allows(granted.copy(tvLimit = "TV-MA"), movie))
        assertFalse(FamilyPolicy.allows(granted, movie.copy(sourceId = "source2")))
    }

    @Test fun refreshingAProviderItemPreservesLocalHistoryAndManualTitles() {
        val item = JellyfinItem("movie1", "Movie", "Movie", year = 2022, rating = "PG")
        val record = requireNotNull(jellyfinMovie("source1", item, null))
        val watched = record.withTitle("Local title").copy(
            isWatched = true, isWatchlisted = true, isLocked = true, playbackPositionMs = 1234,
        )
        val refreshed = requireNotNull(jellyfinMovie("source1", item.copy(rating = "PG-13"), null, watched))
        assertEquals(watched.id, refreshed.id)
        assertEquals("Local title", refreshed.title)
        assertEquals(1234L, refreshed.playbackPositionMs)
        assertTrue(refreshed.isWatched)
        assertTrue(refreshed.isWatchlisted)
        assertEquals("PG-13", refreshed.ageCertification)
    }

    @Test fun providerIDsUseTheMovieOrSeriesIdentityForExactSubDlQueries() {
        val movie = JellyfinItem("movie", "Movie", "Movie", providerIds = mapOf("Tmdb" to "4321"),
            mediaPath = "/private/media/Movie.2026.x265.mkv")
        val film = requireNotNull(jellyfinMovie("source", movie, null))
        assertEquals("Movie.2026.x265.mkv", film.fileName)
        assertEquals("jellyfin/movie.mp4", film.filePath)
        assertEquals(SubDlSearchQuery(4321, SubDlMediaType.MOVIE, language = "en"), subtitleQuery(film, "en"))

        val series = JellyfinItem("series", "Series", "Series", providerIds = mapOf("tmdb" to "5678"))
        val episode = JellyfinItem("episode", "Pilot", "Episode", seriesName = series.name,
            seasonNumber = 2, indexNumber = 4, providerIds = mapOf("Tmdb" to "2345"),
            mediaPath = "C:\\TV\\Series.S02E04.1080p.mp4")
        val record = requireNotNull(jellyfinMovie("source", episode, series))
        assertEquals("Series.S02E04.1080p.mp4", record.fileName)
        assertNull(record.tmdbId)
        assertEquals(SubDlSearchQuery(5678, SubDlMediaType.TV, 2, 4, "es"), subtitleQuery(record, "es"))
        assertNull(subtitleQuery(requireNotNull(jellyfinMovie("source", episode, series.copy(providerIds = emptyMap()))), "en"))
        assertNull(subtitleQuery(requireNotNull(jellyfinMovie("source", movie.copy(providerIds = mapOf("Tmdb" to "-3")), null)), "en"))
    }

    @Test fun unsupportedItemsAndIncompleteEpisodesDoNotEnterTheVideoLibrary() {
        assertNull(jellyfinMovie("source", JellyfinItem("episode", "Fragment", "Episode"), null))
        assertNull(jellyfinMovie("source", JellyfinItem("photo", "Photo", "Photo"), null))
        assertNull(jellyfinItemID("jellyfin/../escape.mp4"))
    }
}
