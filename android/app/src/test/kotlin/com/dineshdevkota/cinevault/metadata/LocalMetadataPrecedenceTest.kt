package com.dineshdevkota.cinevault.metadata

import com.dineshdevkota.cinevault.core.LocalMetadataParser
import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.family.FamilyPolicy
import com.dineshdevkota.cinevault.family.FolderAccess
import com.dineshdevkota.cinevault.family.HouseholdProfile
import org.junit.Assert.*
import org.junit.Test

class LocalMetadataPrecedenceTest {
    private val original = MovieEntity(id = "movie", sourceId = "nas", filePath = "Film (2020).mp4", fileName = "Film (2020).mp4",
        fileSize = 100, parsedTitle = "Film", parsedYear = 2020, title = "Film", year = 2020)
    @Test fun titleOnlySidecarAllowsOnlineMissingFieldsWithoutLosingLocalTitle() {
        val local = LocalMetadataImporter.apply(original, LocalMetadataParser.parse("<movie><title>Our title</title></movie>".toByteArray()), null, null)
        assertFalse(local.metadataFetched)
        val online = local.copy(title = "Online title", overview = "Online plot", posterPath = "/poster.jpg", metadataFetched = true)
        val combined = LocalMetadataImporter.reapply(online)
        assertEquals("Our title", combined.title); assertEquals("Online plot", combined.overview); assertEquals("/poster.jpg", combined.posterPath)
    }
    @Test fun removedOrChangedCertificationCannotLeaveStalePGPermission() {
        val local = LocalMetadataImporter.apply(original, LocalMetadataParser.parse("<movie><mpaa>PG</mpaa><edition>Extended</edition></movie>".toByteArray()), null, null)
        assertEquals("PG", local.ageCertification)
        val removed = LocalMetadataImporter.apply(local, null, null, null)
        assertNull(removed.ageCertification); assertFalse(removed.certificationFetched); assertNull(removed.edition)
        val changed = LocalMetadataImporter.apply(local, LocalMetadataParser.parse("<movie><title>Only a title</title></movie>".toByteArray()), null, null)
        assertNull(changed.ageCertification); assertFalse(changed.certificationFetched)
    }
    @Test fun explicitUnknownCertificationOverridesAnOnlineRating() {
        val local = LocalMetadataImporter.apply(original.copy(ageCertification = "PG", certificationFetched = true),
            LocalMetadataParser.parse("<movie><mpaa>Unknown</mpaa></movie>".toByteArray()), null, null)
        assertNull(local.ageCertification); assertTrue(local.certificationFetched)
        assertNull(LocalMetadataImporter.reapply(local.copy(ageCertification = "PG")).ageCertification)
    }
    @Test fun manualCorrectionsAreNotOverriddenByBackgroundOnlineCompletion() {
        val local = LocalMetadataImporter.apply(original, LocalMetadataParser.parse("<movie><title>Sidecar</title></movie>".toByteArray()), null, null)
        assertEquals("Manual", LocalMetadataImporter.reapply(local.copy(title = "Manual", isLocked = true)).title)
    }
    @Test fun invalidEpisodeSidecarBlocksPermissiveParentAndOnlineRatingUntilRemoved() {
        val episode = original.copy(filePath = "Show/Season 01/Show.S01E01.mp4", fileName = "Show.S01E01.mp4")
        val parent = LocalMetadataParser.parse("<tvshow><title>Show</title><mpaa>TV-G</mpaa></tvshow>".toByteArray())
        val restricted = LocalMetadataImporter.apply(episode,
            LocalMetadataParser.parse("<episodedetails><mpaa>TV-MA</mpaa></episodedetails>".toByteArray()), parent, null)
        val invalid = LocalMetadataImporter.apply(restricted, null, parent, null, invalidSidecar = true)
        assertNull(invalid.ageCertification)
        assertTrue(invalid.certificationFetched)
        assertEquals("Show", invalid.seriesTitle)
        assertNull(LocalMetadataImporter.reapply(invalid.copy(ageCertification = "TV-G")).ageCertification)
        assertEquals("TV-G", LocalMetadataImporter.apply(invalid, null, parent, null).ageCertification)
    }
    @Test fun corruptMetadataBlocksStaleChildPermissionEvenWhenAnotherSidecarIsUnavailable() {
        val episode = original.copy(filePath = "Show/Season 01/Show.S01E01.mp4", fileName = "Show.S01E01.mp4")
        val safe = LocalMetadataImporter.apply(episode,
            LocalMetadataParser.parse("<episodedetails><title>Pilot</title><plot>Saved plot</plot><year>2020</year><genre>Drama</genre><mpaa>TV-G</mpaa></episodedetails>".toByteArray()),
            LocalMetadataParser.parse("<tvshow><title>Saved show</title><uniqueid type='tmdb'>44</uniqueid></tvshow>".toByteArray()), null)
        val child = HouseholdProfile("child", "Child", folders = listOf(FolderAccess(safe.sourceId, "")), tvLimit = "TV-G")
        assertTrue(FamilyPolicy.allows(child, safe))
        for (complete in listOf(false, true)) {
            val invalid = LocalMetadataImporter.apply(safe, null, null, null, metadataComplete = complete, invalidSidecar = true)
            assertNull(invalid.ageCertification)
            assertTrue(invalid.certificationFetched)
            assertFalse(FamilyPolicy.allows(child, invalid))
            assertEquals(safe.title, invalid.title)
            assertEquals(safe.overview, invalid.overview)
            assertEquals(safe.year, invalid.year)
            assertEquals(safe.genres, invalid.genres)
            assertEquals(safe.seriesTitle, invalid.seriesTitle)
            assertEquals(safe.seriesTmdbId, invalid.seriesTmdbId)
            assertNull(LocalMetadataImporter.reapply(invalid.copy(ageCertification = "TV-G")).ageCertification)
        }
    }
    @Test fun unavailableSidecarsAlonePreserveSavedMetadataAndManualCorrectionsWin() {
        val saved = original.copy(title = "Saved title", ageCertification = "PG", certificationFetched = true)
        assertEquals(saved, LocalMetadataImporter.apply(saved, null, null, null, metadataComplete = false))
        val manual = saved.copy(title = "Manual title", isLocked = true)
        for (complete in listOf(false, true)) {
            assertEquals(manual, LocalMetadataImporter.apply(manual, null, null, null, metadataComplete = complete, invalidSidecar = true))
        }
    }
}
