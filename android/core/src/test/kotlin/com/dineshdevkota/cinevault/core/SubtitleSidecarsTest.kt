package com.dineshdevkota.cinevault.core

import org.junit.Assert.*
import org.junit.Test

class SubtitleSidecarsTest {
    private val video = "Media/TV/Show.S01E01.mkv"

    @Test fun acceptsExactStemAndLanguageAccessibilitySuffixesCaseInsensitively() {
        assertNull(SubtitleSidecars.match(video, "Media/TV/Show.S01E01.srt")!!.language)
        val english = SubtitleSidecars.match(video, "media/tv/SHOW.S01E01.ENG.forced.SDH.SRT")!!
        assertEquals("en", english.language)
        assertTrue(english.forced)
        assertTrue(english.hearingImpaired)
        assertEquals("application/x-subrip", english.mimeType)
        val brazilian = SubtitleSidecars.match(video, "Media/TV/Show.S01E01.pt-BR.cc.vtt")!!
        assertEquals("pt-BR", brazilian.language)
        assertTrue(brazilian.hearingImpaired)
        assertEquals("text/vtt", brazilian.mimeType)
    }

    @Test fun unrelatedEpisodeReleaseFolderAndUnsafePathsAreNeverMatched() {
        listOf("Media/TV/Show.S01E010.en.srt", "Media/TV/Show.S01E02.en.srt", "Media/Other/Show.S01E01.en.srt",
            "Media/TV/Show.S01E01.Directors.Cut.srt", "Media/TV/Show.S01E01.en.zip", "../Show.S01E01.srt",
            "Media/TV/Show.S01E01.en.fr.srt", "Media/TV/Show.S01E01.1080p.srt").forEach {
            assertNull(it, SubtitleSidecars.match(video, it))
        }
    }

    @Test fun sourceRootAndIgnoreRulesAreAppliedToBothVideoAndSubtitle() {
        assertTrue(SubtitleSidecars.includesPath("media/TV/Show.en.srt", "Media", emptyList(), emptyList()))
        assertFalse(SubtitleSidecars.includesPath("Media2/Show.srt", "Media", emptyList(), emptyList()))
        assertFalse(SubtitleSidecars.includesPath("Media/TV/Show.srt", "Media", listOf("tv"), emptyList()))
        assertFalse(SubtitleSidecars.includesPath("Media/TV/Show.srt", "Media", emptyList(), listOf("TV/show.srt")))
        assertFalse(SubtitleSidecars.includesPath("Media/../Private/Show.srt", "Media", emptyList(), emptyList()))
    }
}
