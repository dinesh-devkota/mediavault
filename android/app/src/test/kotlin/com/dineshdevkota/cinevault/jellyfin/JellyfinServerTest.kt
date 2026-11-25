package com.dineshdevkota.cinevault.jellyfin

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import okhttp3.OkHttpClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

class JellyfinServerTest {
    @Test fun importedMovieNegotiatesAndSeeksOnLoopbackJellyfin() = runBlocking {
        val password = System.getenv("MEDIAVAULT_JELLYFIN_FIXTURE_PASSWORD")
        assumeTrue("Start the synthetic loopback Jellyfin fixture before this test.", !password.isNullOrEmpty())
        val client = JellyfinClient("http://127.0.0.1:18096/", "mediavault-fixture-test", "1.0",
            allowHttpForFixture = true)
        val session = client.signIn("fixture", requireNotNull(password))
        try {
            val library = client.libraries(session).single { it.name == "Fixture Movies" }
            val catalog = mutableListOf<JellyfinItem>()
            client.catalog(session, library.id) { catalog += it }
            val movie = catalog.single { it.type == "Movie" }
            assertTrue(movie.name.startsWith("Fixture Film"))
            val profile = Json.parseToJsonElement("""
                {
                  "Name": "MediaVault fixture",
                  "MaxStreamingBitrate": 20000000,
                  "DirectPlayProfiles": [{"Type":"Video","Container":"mp4","VideoCodec":"h264","AudioCodec":"aac"}]
                }
                """.trimIndent()).jsonObject
            val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).build()
            val playback = client.playback(session, movie.id, profile)
            assertEquals("DirectPlay", playback.method)
            client.report(session, playback, JellyfinPlaybackEvent.STARTED, 0)
            try {
                val request = client.assetRequest(session, playback.url).newBuilder().header("Range", "bytes=256-287").build()
                http.newCall(request).execute().use { response ->
                        assertEquals(206, response.code)
                        assertTrue(response.header("Content-Range").orEmpty().startsWith("bytes 256-287/"))
                        assertEquals(32, response.body?.bytes()?.size)
                    }
                client.report(session, playback, JellyfinPlaybackEvent.PROGRESS, 1_000)
            } finally {
                client.report(session, playback, JellyfinPlaybackEvent.STOPPED, 1_000)
            }
            val transcodeProfile = Json.parseToJsonElement("""
                {
                  "Name": "MediaVault HLS fixture",
                  "MaxStreamingBitrate": 20000000,
                  "DirectPlayProfiles": [],
                  "TranscodingProfiles": [
                    {"Type":"Video","Context":"Streaming","Protocol":"hls","Container":"ts",
                     "VideoCodec":"h264","AudioCodec":"aac","MaxAudioChannels":"2"}
                  ]
                }
                """.trimIndent()).jsonObject
            val hls = client.playback(session, movie.id, transcodeProfile)
            assertEquals("Transcode", hls.method)
            assertTrue("api_key" !in hls.url.queryParameterNames)
            client.report(session, hls, JellyfinPlaybackEvent.STARTED, 0)
            try {
                val master = http.newCall(client.playbackAssetRequest(session, hls, hls.url)).execute().use { response ->
                    assertEquals(200, response.code)
                    requireNotNull(response.body).string()
                }
                assertTrue(master.startsWith("#EXTM3U"))
                val adaptive = requireNotNull(hls.url.resolve(firstMediaLink(master)))
                val playlist = http.newCall(client.playbackAssetRequest(session, hls, adaptive)).execute().use { response ->
                    assertEquals(200, response.code)
                    requireNotNull(response.body).string()
                }
                assertTrue(playlist.startsWith("#EXTM3U"))
                val segment = requireNotNull(adaptive.resolve(firstMediaLink(playlist)))
                http.newCall(client.playbackAssetRequest(session, hls, segment)).execute().use { response ->
                    assertEquals(200, response.code)
                    assertEquals(16, requireNotNull(response.body).source().readByteArray(16).size)
                }
            } finally {
                client.report(session, hls, JellyfinPlaybackEvent.STOPPED, 0)
            }
        } finally {
            client.signOut(session)
        }
    }

    @Test fun loadsServerArtworkAndPhotosThroughScopedImageRequests() = runBlocking {
        val password = System.getenv("MEDIAVAULT_JELLYFIN_FIXTURE_PASSWORD")
        assumeTrue("Start the synthetic loopback Jellyfin fixture before this test.", !password.isNullOrEmpty())
        val client = JellyfinClient("http://127.0.0.1:18096/", "mediavault-fixture-images", "1.0",
            allowHttpForFixture = true)
        val session = client.signIn("fixture", requireNotNull(password))
        try {
            val libraries = client.libraries(session)
            for ((libraryName, kind) in listOf("Fixture Movies" to "Movie", "Fixture Photos" to "Photo")) {
                val library = libraries.single { it.name == libraryName }
                val items = mutableListOf<JellyfinItem>()
                client.catalog(session, library.id) { items += it }
                val imageItem = items.single { it.type == kind }
                client.openImage(session, imageItem.id, JellyfinImage.Primary, 342).use { response ->
                    assertEquals(200, response.code)
                    val body = requireNotNull(response.body)
                    assertEquals("image", body.contentType()?.type)
                    assertTrue(body.source().request(16L))
                }
            }
        } finally {
            client.signOut(session)
        }
    }

    private fun firstMediaLink(playlist: String): String =
        playlist.lineSequence().map(String::trim).first { it.isNotEmpty() && !it.startsWith("#") }

}
