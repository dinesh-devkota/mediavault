package com.dineshdevkota.cinevault.emby

import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class EmbyPlaybackTest {
    @Test fun signsInListsPagesPlaysSeeksReportsAndSignsOut() = runBlocking {
        MockWebServer().use { socket ->
            socket.enqueue(MockResponse().setBody("""{"AccessToken":"fixture-token","User":{"Id":"viewer","Name":"Viewer"}}"""))
            socket.enqueue(MockResponse().setBody("""{"Items":[{"Id":"library","Name":"Movies","Type":"CollectionFolder"}]}"""))
            socket.enqueue(MockResponse().setBody("""{"Items":[{"Id":"movie-a","Name":"One","Type":"Movie"}],"TotalRecordCount":2}"""))
            socket.enqueue(MockResponse().setBody("""{"Items":[{"Id":"movie-b","Name":"Two","Type":"Movie"}],"TotalRecordCount":2}"""))
            socket.enqueue(playbackResponse())
            socket.enqueue(MockResponse().setResponseCode(204))
            socket.enqueue(MockResponse().setResponseCode(206).addHeader("Content-Range", "bytes 5-8/20").setBody("5678"))
            socket.enqueue(MockResponse().setResponseCode(204))
            socket.enqueue(MockResponse().setResponseCode(204))
            socket.enqueue(MockResponse().setResponseCode(204))
            val client = client(socket)
            val account = client.signIn("Viewer", "fixture-password")
            assertEquals("Movies", client.libraries(account).single().Name)
            val movies = mutableListOf<String>()
            client.catalog(account, "library") { page -> movies += page.map { it.Name } }
            assertEquals(listOf("One", "Two"), movies)
            val playback = client.directPlayback(account, "movie-a", setOf("mp4"))
            assertEquals("mp4", playback.container)
            client.report(account, playback, EmbyClient.PlaybackEvent.STARTED, 0)
            val range = client.read(account, playback, 5, 4)
            assertEquals(20L, range.totalLength)
            assertArrayEquals("5678".toByteArray(), range.bytes)
            client.report(account, playback, EmbyClient.PlaybackEvent.PROGRESS, 500)
            client.report(account, playback, EmbyClient.PlaybackEvent.STOPPED, 500)
            client.signOut(account)

            val signIn = socket.takeRequest()
            assertEquals("POST", signIn.method)
            assertEquals("/emby/Users/AuthenticateByName", signIn.path)
            assertNull(signIn.getHeader("X-Emby-Token"))
            assertTrue(signIn.body.readUtf8().contains("fixture-password"))
            val library = socket.takeRequest()
            assertEquals("/emby/Users/viewer/Views", library.path)
            assertEquals("fixture-token", library.getHeader("X-Emby-Token"))
            assertEquals("0", socket.takeRequest().requestUrl?.queryParameter("StartIndex"))
            assertEquals("1", socket.takeRequest().requestUrl?.queryParameter("StartIndex"))
            val playbackInfo = socket.takeRequest()
            assertEquals("/emby/Items/movie-a/PlaybackInfo", playbackInfo.requestUrl?.encodedPath)
            assertEquals("viewer", playbackInfo.requestUrl?.queryParameter("UserId"))
            assertEquals("/emby/Sessions/Playing", socket.takeRequest().path)
            val read = socket.takeRequest()
            assertEquals("/emby/Videos/movie-a/stream", read.requestUrl?.encodedPath)
            assertEquals("true", read.requestUrl?.queryParameter("Static"))
            assertEquals("fixture-source", read.requestUrl?.queryParameter("MediaSourceId"))
            assertEquals("fixture-session", read.requestUrl?.queryParameter("PlaySessionId"))
            assertEquals("bytes=5-8", read.getHeader("Range"))
            assertFalse(read.path.orEmpty().contains("fixture-token"))
            val progress = socket.takeRequest()
            assertEquals("/emby/Sessions/Playing/Progress", progress.path)
            assertTrue(progress.body.readUtf8().contains("5000000"))
            assertEquals("/emby/Sessions/Playing/Stopped", socket.takeRequest().path)
            assertEquals("/emby/Sessions/Logout", socket.takeRequest().path)
        }
    }

    @Test fun ignoresNoRangeAndRejectsIncorrectRangeAndRedirect() {
        MockWebServer().use { socket ->
            socket.enqueue(playbackResponse())
            socket.enqueue(MockResponse().setResponseCode(200).setBody("unrequested whole file"))
            socket.enqueue(MockResponse().setResponseCode(206).addHeader("Content-Range", "bytes 5-8/8").setBody("5678"))
            socket.enqueue(MockResponse().setResponseCode(302).addHeader("Location", socket.url("/outside")))
            val client = client(socket)
            val account = EmbyClient.Account("fixture-token", EmbyClient.User("viewer", "Viewer"))
            val playback = runBlocking { client.directPlayback(account, "movie-a", setOf("mp4")) }
            repeat(3) {
                assertThrows(EmbyException::class.java) { runBlocking { client.read(account, playback, 5, 4) } }
            }
            assertEquals(4, socket.requestCount)
        }
    }

    @Test fun unsupportedContainerCannotBecomeDirectPlay() {
        MockWebServer().use { socket ->
            socket.enqueue(playbackResponse())
            val client = client(socket)
            val account = EmbyClient.Account("fixture-token", EmbyClient.User("viewer", "Viewer"))
            assertThrows(EmbyException::class.java) { runBlocking { client.directPlayback(account, "movie-a", setOf("mov")) } }
            assertEquals(1, socket.requestCount)
        }
    }

    private fun client(server: MockWebServer): EmbyClient =
        EmbyClient(server.url("/emby/").newBuilder().host("127.0.0.1").build().toString(), "fixture-device", "1.0",
            OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).build(), allowLoopbackHttp = true)

    private fun playbackResponse() = MockResponse().setBody(
        """{"PlaySessionId":"fixture-session","MediaSources":[{"Id":"fixture-source","Container":"mp4","SupportsDirectPlay":true}]}""",
    )
}
