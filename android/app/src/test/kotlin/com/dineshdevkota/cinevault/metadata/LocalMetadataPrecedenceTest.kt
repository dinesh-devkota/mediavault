package com.dineshdevkota.cinevault.metadata

import com.dineshdevkota.cinevault.core.LocalMetadataParser
import com.dineshdevkota.cinevault.data.MovieEntity
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
        val invalid = LocalMetadataImporter.apply(restricted, null, parent, null, invalidDetails = true)
        assertNull(invalid.ageCertification)
        assertTrue(invalid.certificationFetched)
        assertEquals("Show", invalid.seriesTitle)
        assertNull(LocalMetadataImporter.reapply(invalid.copy(ageCertification = "TV-G")).ageCertification)
        assertEquals("TV-G", LocalMetadataImporter.apply(invalid, null, parent, null).ageCertification)
    }
}
