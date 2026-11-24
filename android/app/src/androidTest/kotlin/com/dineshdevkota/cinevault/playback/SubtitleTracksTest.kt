@file:OptIn(UnstableApi::class)

package com.dineshdevkota.cinevault.playback

import androidx.annotation.OptIn
import androidx.media3.common.Format
import androidx.media3.common.Tracks
import androidx.media3.common.TrackGroup
import androidx.media3.common.C
import androidx.media3.common.TrackSelectionParameters
import androidx.media3.common.util.UnstableApi
import androidx.media3.extractor.DummyTrackOutput
import androidx.media3.extractor.ExtractorOutput
import androidx.media3.extractor.SeekMap
import androidx.media3.extractor.TrackOutput
import androidx.media3.extractor.text.CuesWithTiming
import androidx.media3.extractor.text.DefaultSubtitleParserFactory
import androidx.media3.extractor.text.SubtitleParser
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.core.app.ApplicationProvider
import com.dineshdevkota.cinevault.CineVaultApp
import com.dineshdevkota.cinevault.data.Settings
import com.dineshdevkota.cinevault.data.SecretBox
import com.dineshdevkota.cinevault.core.SubtitleSidecars
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SubtitleTracksTest {
    @Test fun parserRejectsCorruptAndOversizedOptionalCaptions() {
        fun configuration(text: ByteArray, mime: String = "application/x-subrip") =
            SubtitleTracks.configuration(text, mime, "en", "English", "fixture")
        val srt = "1\n00:00:00,100 --> 00:00:02,000\nHello\n".toByteArray()
        assertNotNull(configuration(srt))
        assertNotNull(configuration("WEBVTT\n\n00:00.100 --> 00:02.000\nHello\n".toByteArray(), "text/vtt"))
        assertNull(configuration("not a subtitle".toByteArray()))
        assertNull(configuration(ByteArray(2 * 1024 * 1024 + 1)))
        assertNull(configuration("bad header".toByteArray(), "text/vtt"))

        // Seek into the final cue, after its start: duration must include the whole cue.
        val finalCueFixture = "1\n00:00:00,500 --> 00:00:05,000\nFirst cue\n\n" +
            "2\n00:00:05,500 --> 00:00:11,500\nFinal cue\n"
        val prepared = checkNotNull(configuration(finalCueFixture.toByteArray()))
        val extractor = SubtitleMediaSourceFactory.extractor(prepared)
        var declaredDurationUs = C.TIME_UNSET
        extractor.init(object : ExtractorOutput {
            override fun track(id: Int, type: Int): TrackOutput = DummyTrackOutput()
            override fun endTracks() = Unit
            override fun seekMap(seekMap: SeekMap) {
                assertTrue(seekMap.isSeekable)
                declaredDurationUs = seekMap.durationUs
            }
        })
        assertEquals("A final cue remains seekable until its end", 11_500_000L, declaredDurationUs)
        extractor.release()
        val parser = DefaultSubtitleParserFactory().create(Format.Builder().setSampleMimeType("application/x-subrip").build())
        val parsed = mutableListOf<CuesWithTiming>()
        parser.parse(finalCueFixture.toByteArray(), SubtitleParser.OutputOptions.allCues()) { parsed += it }
        assertEquals(listOf(500_000L, 5_500_000L), parsed.map { it.startTimeUs })
        assertEquals(listOf(5_000_000L, 11_500_000L), parsed.map { it.endTimeUs })
        parsed.clear()
        parser.parse(finalCueFixture.toByteArray(), SubtitleParser.OutputOptions.cuesAfterThenRemainingCuesBefore(6_500_000)) { parsed += it }
        assertEquals("Final cue", parsed.first().cues.single().text.toString())
        assertEquals(11_500_000L, parsed.first().endTimeUs)
        parser.reset()
    }

    @Test fun nativeNoneMeansOffAndChoosingALanguageClearsItsSuppressionFlags() {
        val none = TrackSelectionParameters.DEFAULT.buildUpon()
            .setIgnoredTextSelectionFlags(C.SELECTION_FLAG_FORCED.inv()).build()
        assertEquals("off", SubtitleTracks.explicitPreference(none))
        val off = SubtitleTracks.applyPreference(none, "off")
        assertTrue(C.TRACK_TYPE_TEXT in off.disabledTrackTypes)
        val spanish = SubtitleTracks.applyPreference(off, "es")
        assertFalse(C.TRACK_TYPE_TEXT in spanish.disabledTrackTypes)
        assertEquals(listOf("es"), spanish.preferredTextLanguages)
        assertNull(SubtitleTracks.explicitPreference(spanish))
    }

    @Test fun downloadedReleaseWinsOverCompetingEnglishTracksOnlyWhenItsIdArrives() {
        fun group(id: String, selected: Boolean) = Tracks.Group(
            TrackGroup(id, Format.Builder().setId(id).setSampleMimeType("application/x-subrip").setLanguage("en").build()),
            false, intArrayOf(C.FORMAT_HANDLED), booleanArrayOf(selected),
        )
        val embedded = group("embedded", true)
        val local = group("local", false)
        val downloaded = group("subdl:123", false)
        val preference = SubtitleTracks.applyPreference(TrackSelectionParameters.DEFAULT, "en")
        assertNull(SubtitleTracks.selectById(preference, Tracks(listOf(embedded, local)), "subdl:123"))
        val selected = SubtitleTracks.selectById(preference, Tracks(listOf(embedded, local, downloaded)), "subdl:123")!!
        assertEquals("subdl:123", selected.overrides.values.single().mediaTrackGroup.id)
        assertEquals(listOf(0), selected.overrides.values.single().trackIndices)
        assertFalse(SubtitleTracks.sameLanguage("pt-PT", "pt-BR"))
        assertFalse(SubtitleTracks.sameLanguage("zh-Hans", "zh-Hant"))
        assertTrue(SubtitleTracks.sameLanguage("eng", "en"))
    }

    @Test fun explicitTrackLanguageCarriesAcrossSettingsReloadWithoutOffLosingIt() {
        val context = ApplicationProvider.getApplicationContext<CineVaultApp>()
        val settings = context.container.settings
        val previousLanguage = settings.subtitleLanguage
        val previousPreference = settings.subtitlePreference
        try {
            settings.subtitleLanguage = "en"
            settings.subtitlePreference = "spa"
            val reloaded = Settings(context, SecretBox())
            assertEquals("es", reloaded.subtitlePreference)
            assertEquals("A later online search must follow the selected Spanish track", "es", reloaded.subtitleLanguage)
            reloaded.subtitlePreference = "off"
            assertEquals("off", settings.subtitlePreference)
            assertEquals("es", settings.subtitleLanguage)
            assertNull("Undetermined language is a playback choice, not a search language", SubtitleSidecars.normalizeLanguage("und"))
            reloaded.subtitlePreference = "und"
            assertEquals("es", settings.subtitleLanguage)
        } finally {
            settings.subtitlePreference = previousPreference
            settings.subtitleLanguage = previousLanguage
        }
    }

    @Test fun automaticReleaseMatchingNeverGuessesAlternateCutsOrSimilarEpisodes() {
        assertTrue(SubtitleTracks.exactRelease("Show.S01E01.1080p.mkv", "show.s01e01.1080p"))
        assertFalse(SubtitleTracks.exactRelease("Show.S01E01.1080p.mkv", "Show.S01E010.1080p"))
        assertFalse(SubtitleTracks.exactRelease("Movie.Directors.Cut.mkv", "Movie.Theatrical"))
        assertFalse(SubtitleTracks.exactRelease("Movie.mkv", "Movie.1080p"))
    }
}
