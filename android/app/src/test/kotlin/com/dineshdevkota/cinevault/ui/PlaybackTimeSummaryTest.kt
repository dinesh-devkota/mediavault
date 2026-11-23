package com.dineshdevkota.cinevault.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PlaybackTimeSummaryTest {
    @Test fun usesActualFileDurationBeforeMetadata() {
        assertEquals("About 1h 30m left", remainingPlaybackTime(7_200_000, 90, 1_800_000))
        assertEquals("About 1h left", remainingPlaybackTime(3_660_000, null, 60_000))
    }

    @Test fun fallsBackToMetadataAndRoundsUp() {
        assertEquals("About 30 min left", remainingPlaybackTime(0, 90, 3_600_000))
        assertEquals("About 2 min left", remainingPlaybackTime(122_000, null, 61_000))
        assertEquals("Less than a minute left", remainingPlaybackTime(120_000, null, 61_000))
    }

    @Test fun unknownInvalidOrCompletedTimeDoesNotInventAnEstimate() {
        assertNull(remainingPlaybackTime(0, null, 40_000))
        assertNull(remainingPlaybackTime(120_000, 2, 120_000))
        assertNull(remainingPlaybackTime(120_000, 2, 150_000))
        assertNull(remainingPlaybackTime(120_000, null, -1))
        assertNull(remainingPlaybackTime(-1, -1, 40_000))
    }
}
