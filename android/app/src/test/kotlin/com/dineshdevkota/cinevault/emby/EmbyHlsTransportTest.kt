package com.dineshdevkota.cinevault.emby

import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.*
import org.junit.Test

class EmbyHlsTransportTest {
    @Test
    fun removesEncodedCredentialsBeforeThePlayerSeesAnyPlaylistReferences() = runBlocking<Unit> {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody("""
                {"PlaySessionId":"session","MediaSources":[{"Id":"source",
                 "TranscodingUrl":"/videos/movie/master.m3u8?api-key=alternate&%66ixture-token=hidden&VideoCodec=h264"}]}
            """.trimIndent()))
            server.enqueue(MockResponse().setBody("""
                #EXTM3U
                #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="text",NAME="English",URI="text.m3u8?x-emby-token=different"
                #EXT-X-STREAM-INF:BANDWIDTH=500000,SUBTITLES="text"
                main.m3u8?%61pi_key=%66ixture%2Dtoken
            """.trimIndent()))
            val base = server.url("/emby/").newBuilder().host("127.0.0.1").build()
            val client = EmbyClient(base.toString(), "fixture-device", "1.0",
                OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).build(), allowLoopbackHttp = true)
            val account = EmbyClient.Account("fixture-token", EmbyClient.User("viewer", "Viewer"))
            val playback = client.transcode(account, "movie")
            val entry = playback.manifest.toString()
            assertFalse(entry.contains("api-key"))
            assertFalse(entry.contains(account.AccessToken))
            assertEquals("h264", playback.manifest.queryParameter("VideoCodec"))
            val (url, body) = client.readHls(account, playback, entry)
            val playlist = body.toString(Charsets.UTF_8)
            assertTrue(playlist.contains("${base}videos/movie/text.m3u8?"))
            assertTrue(playlist.contains("${base}videos/movie/main.m3u8?"))
            for (secret in listOf("different", "hidden", "fixture-token", "%66ixture", "api_key", "x-emby-token")) {
                assertFalse(playlist.contains(secret))
            }
            val negotiation = server.takeRequest()
            assertEquals("POST", negotiation.method)
            assertEquals("fixture-token", server.takeRequest().getHeader("X-Emby-Token"))
            assertThrows(EmbyException::class.java) {
                client.readHls(account, playback, requireNotNull(url.resolve("fixture-token/main.m3u8")).toString())
            }
            assertThrows(EmbyException::class.java) {
                client.readHls(account, playback, requireNotNull(url.resolve("../other/main.m3u8")).toString())
            }
            assertEquals(2, server.requestCount)
        }
    }
}
