package com.dineshdevkota.cinevault.core

import org.junit.Assert.*
import org.junit.Test

class LocalMediaMetadataTest {
    @Test fun parsesMovieAndCollectionWithoutRemoteArtwork() {
        val parsed = LocalMetadataParser.parse("""<movie><title>Home &amp; Away</title><plot>Our film</plot><year>2020</year><genre>Documentary</genre><runtime>92</runtime><mpaa>Rated PG</mpaa><uniqueid type="tmdb">123</uniqueid><set><name>Family films</name></set><thumb>https://untrusted.invalid/poster.jpg</thumb></movie>""".toByteArray())
        assertEquals("Home & Away", parsed.title)
        assertEquals("Family films", parsed.collection)
        assertEquals("PG", parsed.certification)
        assertEquals(123, parsed.tmdbId)
        assertEquals(listOf("Documentary"), parsed.genres)
    }
    @Test fun episodeFieldsAndSimpleSetAreRead() {
        val item = LocalMetadataParser.parse("<episodedetails><title>Pilot</title><showtitle>Home Show</showtitle><season>2</season><episode>3</episode><set>Favorites</set></episodedetails>".toByteArray())
        assertEquals("Home Show", item.showTitle); assertEquals(2, item.season); assertEquals(3, item.episode); assertEquals("Favorites", item.collection)
    }
    @Test fun unknownCertificationDoesNotBecomeAudienceScore() {
        val item = LocalMetadataParser.parse("<movie><rating>9.1</rating><mpaa>Unknown</mpaa><year>-1</year><runtime>-9</runtime><tmdbid>-1</tmdbid></movie>".toByteArray())
        assertNull(item.certification); assertNull(item.year); assertNull(item.runtime); assertNull(item.tmdbId)
    }
    @Test fun externalEntitiesAndDoctypesAreRejected() {
        for (xml in listOf("<!DOCTYPE movie [<!ENTITY x SYSTEM 'file:///private'>]><movie><title>&x;</title></movie>", "<!DOCTYPE movie><movie/>", "<html>Login</html>")) {
            assertTrue(runCatching { LocalMetadataParser.parse(xml.toByteArray()) }.isFailure)
        }
    }
    @Test fun oversizedMalformedAndUtf16AreRejected() {
        assertTrue(runCatching { LocalMetadataParser.parse(ByteArray(LocalMetadataParser.MAX_BYTES + 1) { 65 }) }.isFailure)
        assertTrue(runCatching { LocalMetadataParser.parse("<movie><title>broken".toByteArray()) }.isFailure)
        assertTrue(runCatching { LocalMetadataParser.parse("<movie/>".toByteArray(Charsets.UTF_16)) }.isFailure)
    }
    @Test fun labelsDescribeOnlyRecognizedFilenameTags() {
        assertEquals("Directors Cut · 2160P", MediaVersions.label("Movie {edition-Directors Cut} 2160p.mkv"))
        assertEquals("Original file", MediaVersions.label("A memory.mp4"))
    }
}
