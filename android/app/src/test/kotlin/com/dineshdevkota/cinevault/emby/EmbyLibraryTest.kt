package com.dineshdevkota.cinevault.emby

import com.dineshdevkota.cinevault.family.FamilyPolicy
import com.dineshdevkota.cinevault.family.FolderAccess
import com.dineshdevkota.cinevault.family.HouseholdProfile
import org.junit.Assert.*
import org.junit.Test

class EmbyLibraryTest {
    @Test fun importsStableEpisodeIdentityAndUsesSeriesAgeRating() {
        val movie = EmbyClient.Item("episode-id", "Pilot", "Episode", SeriesId = "series-id",
            SeriesName = "Fixture Show", ParentIndexNumber = 1, IndexNumber = 2, OfficialRating = "TV-G")
        val series = EmbyClient.Item("series-id", "Fixture Show", "Series", OfficialRating = "TV-MA", ProviderIds = mapOf("Tmdb" to "101"))
        val item = checkNotNull(embyMovie("source-id", movie, series, null))
        assertEquals("TV-MA", item.ageCertification)
        assertEquals(101, item.seriesTmdbId)
        assertEquals("episode-id", embyItemId(item.filePath))
        assertEquals(1, item.episodeInfo?.season)
        assertEquals(2, item.episodeInfo?.episode)
        assertFalse(FamilyPolicy.allows(HouseholdProfile("viewer", "Viewer"), item))
        val granted = HouseholdProfile("viewer", "Viewer", folders = listOf(FolderAccess("source-id", "")), tvLimit = "TV-14")
        assertFalse(FamilyPolicy.allows(granted, item))
        assertTrue(FamilyPolicy.allows(granted.copy(tvLimit = "TV-MA"), item))
    }

    @Test fun rescansPreserveLocalIdentityAndHistory() {
        val item = EmbyClient.Item("movie-id", "Server title", "Movie", OfficialRating = "PG")
        val previous = checkNotNull(embyMovie("source-id", item, null, null))
            .withTitle("Owner title").copy(isLocked = true, isWatchlisted = true, playbackPositionMs = 50_000)
        val refreshed = checkNotNull(embyMovie("source-id", item.copy(Name = "Changed title"), null, previous))
        assertEquals(previous.id, refreshed.id)
        assertEquals("Owner title", refreshed.title)
        assertTrue(refreshed.isWatchlisted)
        assertEquals(50_000L, refreshed.playbackPositionMs)
    }

    @Test fun malformedEpisodesAndProviderIdentifiersAreRejected() {
        val incomplete = EmbyClient.Item("episode", "Pilot", "Episode", SeriesName = "Show", IndexNumber = 1)
        assertNull(embyMovie("source-id", incomplete, null, null))
        assertNull(embyItemId("emby/../../outside.mp4"))
        assertNull(embyItemId("emby/%2f.mp4"))
        assertNull(embyItemId("emby/..mp4"))
        assertThrows(EmbyException::class.java) {
            embyMovie("source-id", EmbyClient.Item("../outside", "Fixture", "Movie"), null, null)
        }
    }
}
