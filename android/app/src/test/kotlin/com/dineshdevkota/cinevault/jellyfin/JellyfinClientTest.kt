package com.dineshdevkota.cinevault.jellyfin

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.buildJsonObject
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class JellyfinClientTest {
    private val account = """{"AccessToken":"fixture-token","User":{"Id":"account","Name":"Fixture"}}"""

    @Test fun passwordLoginFiltersLibrariesAndImportsTwoPagesWithoutProviderHistory() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(json(account))
            server.enqueue(json("""{"Items":[{"Id":"lib","Name":"Media","Type":"CollectionFolder"}]}"""))
            server.enqueue(json("""{"StartIndex":0,"TotalRecordCount":2,"Items":[{"Id":"show","Name":"Series","Type":"Series"}]}"""))
            server.enqueue(json("""{"StartIndex":1,"TotalRecordCount":2,"Items":[{"Id":"episode","Name":"Pilot","Type":"Episode","SeriesId":"show","SeasonId":"season","ParentIndexNumber":1,"IndexNumber":1}]}"""))
            val client = fixture(server)
            val session = client.signIn("viewer", "p\"ass")
            val libraries = client.libraries(session)
            val items = mutableListOf<JellyfinItem>()
            client.catalog(session, libraries.single().id) { items += it }
            assertEquals(listOf("show", "episode"), items.map { it.id })
            assertEquals("show", items.last().seriesId)
            assertEquals(1, items.last().seasonNumber)

            val signIn = server.takeRequest()
            assertEquals("/jellyfin/Users/AuthenticateByName", signIn.path)
            assertEquals("POST", signIn.method)
            assertEquals("""{"Username":"viewer","Pw":"p\"ass"}""", signIn.body.readUtf8())
            assertFalse(signIn.getHeader("Authorization").orEmpty().contains("Token="))
            assertEquals("/jellyfin/UserViews", server.takeRequest().requestUrl?.encodedPath)
            for (start in listOf("0", "1")) {
                val request = server.takeRequest()
                assertTrue(request.getHeader("Authorization").orEmpty().contains("""Token="fixture-token""""))
                assertEquals("lib", request.requestUrl?.queryParameter("parentId"))
                assertEquals(start, request.requestUrl?.queryParameter("startIndex"))
                assertEquals("false", request.requestUrl?.queryParameter("enableUserData"))
                assertEquals("Overview,ProviderIds,Path", request.requestUrl?.queryParameter("fields"))
            }
        }
    }

    @Test fun quickConnectAndLogoutUseScopedRequests() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(json("""{"Secret":"secret+/","Code":"128356","Authenticated":false}"""))
            server.enqueue(json("""{"Secret":"secret+/","Code":"128356","Authenticated":true}"""))
            server.enqueue(json(account))
            server.enqueue(MockResponse().setResponseCode(204))
            val client = fixture(server)
            val initial = client.beginQuickConnect()
            assertFalse(initial.authenticated)
            assertTrue(client.pollQuickConnect(initial.secret).authenticated)
            client.signOut(client.finishQuickConnect(initial.secret))
            assertEquals("/jellyfin/QuickConnect/Initiate", server.takeRequest().path)
            assertEquals("secret+/", server.takeRequest().requestUrl?.queryParameter("secret"))
            assertEquals("""{"Secret":"secret+/"}""", server.takeRequest().body.readUtf8())
            val logout = server.takeRequest()
            assertEquals("/jellyfin/Sessions/Logout", logout.path)
            assertTrue(logout.getHeader("Authorization").orEmpty().contains("fixture-token"))
        }
    }

    @Test fun redirectsDoNotForwardSignIn() {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(302).setHeader("Location", "/redirected"))
            val error = assertThrows(JellyfinException::class.java) { runBlocking { fixture(server).signIn("viewer", "password") } }
            assertEquals(302, error.status)
            assertEquals(1, server.requestCount)
        }
    }

    @Test fun repeatedCatalogIdsFailBeforePublishingTheInvalidPage() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(json(account))
            val item = """{"Id":"repeat","Name":"Film","Type":"Movie"}"""
            server.enqueue(json("""{"StartIndex":0,"TotalRecordCount":2,"Items":[$item]}"""))
            server.enqueue(json("""{"StartIndex":1,"TotalRecordCount":2,"Items":[$item]}"""))
            val client = fixture(server)
            val session = client.signIn("viewer", "password")
            val published = mutableListOf<JellyfinItem>()
            assertThrows(JellyfinException::class.java) {
                runBlocking { client.catalog(session, "library") { published += it } }
            }
            assertEquals(listOf("repeat"), published.map { it.id })
        }
    }

    @Test fun playbackNegotiationReportsAndStopsTheSameSession() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(json(account))
            server.enqueue(json("""{"PlaySessionId":"play","MediaSources":[{"Id":"source","SupportsDirectPlay":true,"MediaStreams":[{"Type":"Subtitle","Index":2,"IsTextSubtitleStream":true,"Language":"eng"}]}]}"""))
            repeat(3) { server.enqueue(MockResponse().setResponseCode(204)) }
            val client = fixture(server)
            val session = client.signIn("viewer", "password")
            val playback = client.playback(session, "movie", buildJsonObject {}, startMillis = 2000)
            assertEquals("DirectPlay", playback.method)
            assertEquals("/jellyfin/Videos/movie/stream", playback.url.encodedPath)
            assertEquals("true", playback.url.queryParameter("static"))
            assertEquals("/jellyfin/Videos/movie/source/Subtitles/2/Stream.vtt", playback.subtitles.single().url.encodedPath)
            assertTrue(client.assetRequest(session, playback.url).header("Authorization").orEmpty().contains("fixture-token"))
            client.report(session, playback, JellyfinPlaybackEvent.STARTED, 2000)
            client.report(session, playback, JellyfinPlaybackEvent.PROGRESS, 3560, paused = true)
            client.report(session, playback, JellyfinPlaybackEvent.STOPPED, 3560)
            server.takeRequest()
            assertTrue(server.takeRequest().body.readUtf8().contains("\"StartTimeTicks\":20000000"))
            assertEquals("/jellyfin/Sessions/Playing", server.takeRequest().path)
            assertTrue(server.takeRequest().body.readUtf8().contains("\"PositionTicks\":35600000"))
            val stopped = server.takeRequest()
            assertEquals("/jellyfin/Sessions/Playing/Stopped", stopped.path)
            assertTrue(stopped.body.readUtf8().contains("\"PlaySessionId\":\"play\""))
        }
    }

    @Test fun serverSuppliedTranscodeStaysUnderReverseProxyAndDropsQueryToken() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(json(account))
            server.enqueue(json("""{"PlaySessionId":"play","MediaSources":[{"Id":"source","TranscodingUrl":"/videos/movie/master.m3u8?api_key=secret&PlaySessionId=play"}]}"""))
            server.enqueue(json("""{"PlaySessionId":"play","MediaSources":[{"Id":"source","TranscodingUrl":"https://foreign.example/videos/movie/master.m3u8"}]}"""))
            val client = fixture(server)
            val session = client.signIn("viewer", "password")
            val playback = client.playback(session, "movie", buildJsonObject {})
            assertEquals("Transcode", playback.method)
            assertEquals("/jellyfin/videos/movie/master.m3u8", playback.url.encodedPath)
            assertEquals(setOf("PlaySessionId"), playback.url.queryParameterNames)
            val segment = client.playbackAssetRequest(session, playback,
                server.url("/jellyfin/Videos/movie/hls/main/1.ts?api_key=from-manifest"))
            assertFalse("api_key" in segment.url.queryParameterNames)
            assertTrue(segment.header("Authorization").orEmpty().contains("fixture-token"))
            assertThrows(JellyfinException::class.java) {
                client.playbackAssetRequest(session, playback, server.url("/jellyfin/Videos/another-item/stream"))
            }
            assertThrows(JellyfinException::class.java) {
                runBlocking { client.playback(session, "movie", buildJsonObject {}) }
            }
            assertEquals(3, server.requestCount)
            assertThrows(JellyfinException::class.java) { client.assetRequest(session, server.url("/outside/segment.ts")) }
            Unit
        }
    }

    private fun fixture(server: MockWebServer) =
        JellyfinClient(server.url("/jellyfin/").toString(), "fixture-device", "1.0", allowHttpForFixture = true)

    private fun json(body: String) = MockResponse().setHeader("Content-Type", "application/json").setBody(body)
}
