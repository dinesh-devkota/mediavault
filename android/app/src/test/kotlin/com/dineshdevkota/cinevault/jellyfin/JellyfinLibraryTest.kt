package com.dineshdevkota.cinevault.jellyfin

import com.dineshdevkota.cinevault.family.FamilyPolicy
import com.dineshdevkota.cinevault.family.FolderAccess
import com.dineshdevkota.cinevault.family.HouseholdProfile
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

    @Test fun unsupportedItemsAndIncompleteEpisodesDoNotEnterTheVideoLibrary() {
        assertNull(jellyfinMovie("source", JellyfinItem("episode", "Fragment", "Episode"), null))
        assertNull(jellyfinMovie("source", JellyfinItem("photo", "Photo", "Photo"), null))
        assertNull(jellyfinItemID("jellyfin/../escape.mp4"))
    }
}
