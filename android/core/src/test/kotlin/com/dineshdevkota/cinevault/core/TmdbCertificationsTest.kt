package com.dineshdevkota.cinevault.core

import org.junit.Assert.*
import org.junit.Test

class TmdbCertificationsTest {
    @Test fun movieUsesStrictestUSReleaseAndIgnoresForeignRatings() {
        val details = Tmdb.json.decodeFromString<TmdbMovieDetails>("""{"id":1,"release_dates":{"results":[{"iso_3166_1":"GB","release_dates":[{"certification":"18"}]},{"iso_3166_1":"US","release_dates":[{"certification":"PG"},{"certification":"R"}]}]}}""")
        assertEquals("R", details.releaseDates?.usRating)
    }
    @Test fun unratedOrMissingPayloadIsNeverAnInventedAge() {
        assertNull(Tmdb.json.decodeFromString<TmdbMovieDetails>("""{"id":1}""").releaseDates)
        val empty = Tmdb.json.decodeFromString<TmdbMovieDetails>("""{"id":1,"release_dates":{"results":[]}}""")
        assertNotNull(empty.releaseDates)
        assertNull(empty.releaseDates?.usRating)
        assertNull(TmdbReleaseDates(listOf(TmdbReleaseCountry("US", listOf(TmdbRelease("NR"), TmdbRelease("G"))))).usRating)
    }
    @Test fun televisionUsesUSSeriesRatingAndFantasyViolenceAlias() {
        val details = Tmdb.json.decodeFromString<TmdbTVDetails>("""{"id":1,"content_ratings":{"results":[{"iso_3166_1":"US","rating":"TV-G"},{"iso_3166_1":"US","rating":"TV-Y7-FV"}]}}""")
        assertEquals("TV-Y7", details.contentRatings?.usRating)
    }
    @Test fun requestsAppendOnlyTheRelevantCertificationResource() {
        assertEquals("release_dates", Tmdb.detailsRequest(1, "fixture").url.queryParameter("append_to_response"))
        assertEquals("content_ratings", Tmdb.tvDetailsRequest(1, "fixture").url.queryParameter("append_to_response"))
    }
}
