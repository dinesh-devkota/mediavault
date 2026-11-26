package com.dineshdevkota.cinevault.emby

import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

class EmbyLiveServerTest {
    @Test fun authenticatesCatalogsSeeksAndReportsOnTheOfficialServer() = runBlocking {
        val password = System.getenv("MEDIAVAULT_EMBY_FIXTURE_PASSWORD")
        assumeTrue("Run scripts/test_emby_fixture.py to exercise the local Emby server", !password.isNullOrEmpty())
        val client = EmbyClient("http://127.0.0.1:18097/emby/", "fixture-android", "1.0",
            OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).build(), allowLoopbackHttp = true)
        val account = client.signIn("fixture", requireNotNull(password))
        try {
            val library = client.libraries(account).single { it.Name == "Fixture Movies" }
            val catalog = mutableListOf<EmbyClient.Item>()
            client.catalog(account, library.Id) { catalog += it }
            val movie = catalog.single { it.Type == "Movie" && it.Name.startsWith("Fixture Movie") }
            val photoLibrary = client.libraries(account).single { it.Name == "Fixture Photos" }
            val photos = mutableListOf<EmbyClient.Item>()
            client.catalog(account, photoLibrary.Id) { photos += it.filter { item -> item.Type == "Photo" } }
            val image = client.primaryImage(account, photos.single().Id, 512)
            assertTrue(image.size > 100)
            assertEquals(0xff.toByte(), image[0])
            assertEquals(0xd8.toByte(), image[1])
            val playback = client.directPlayback(account, movie.Id, setOf("mp4"))
            val subtitle = client.textSubtitle(account, playback, playback.textSubtitles.single())
            assertTrue(subtitle.toString(Charsets.UTF_8).contains("Hello from Emby fixture"))
            client.report(account, playback, EmbyClient.PlaybackEvent.STARTED, 0)
            try {
                val first = client.read(account, playback, 0, 16)
                val seek = client.read(account, playback, 1024, 32)
                assertEquals(first.totalLength, seek.totalLength)
                assertEquals("ftyp", String(first.bytes.copyOfRange(4, 8), Charsets.US_ASCII))
                assertEquals(32, seek.bytes.size)
                assertTrue(seek.totalLength > 1055)
                client.report(account, playback, EmbyClient.PlaybackEvent.PROGRESS, 500)
            } finally {
                client.report(account, playback, EmbyClient.PlaybackEvent.STOPPED, 500)
            }
            val transcodeItem = catalog.single { it.Type == "Movie" && it.Name.startsWith("Fixture Transcode") }
            assertEquals(null, client.directPlaybackIfSupported(account, transcodeItem.Id, setOf("mkv"), setOf("h264")))
            val hls = client.transcode(account, transcodeItem.Id)
            try {
                assertTrue(hls.manifest.queryParameter("api_key") == null)
                val (masterUrl, master) = client.readHls(account, hls, hls.manifest.toString())
                val variant = master.toString(Charsets.UTF_8).lineSequence().first { it.isNotBlank() && !it.startsWith("#") }
                val (playlistUrl, playlist) = client.readHls(account, hls, requireNotNull(masterUrl.resolve(variant)).toString())
                val chunks = playlist.toString(Charsets.UTF_8).lineSequence().filter { it.isNotBlank() && !it.startsWith("#") }.take(2).toList()
                assertEquals(2, chunks.size)
                for (chunk in chunks) {
                    assertTrue(client.readHls(account, hls, requireNotNull(playlistUrl.resolve(chunk)).toString()).second.size > 1024)
                }
            } finally {
                client.stopTranscode(account, hls)
            }
        } finally {
            client.signOut(account)
        }
    }
}
