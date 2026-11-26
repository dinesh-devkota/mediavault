@file:OptIn(UnstableApi::class)

package com.dineshdevkota.cinevault.emby

import android.content.Context
import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.ui.PlayerView
import androidx.room.Room
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.dineshdevkota.cinevault.MainActivity
import com.dineshdevkota.cinevault.data.CineVaultDatabase
import com.dineshdevkota.cinevault.data.SecretBox
import com.dineshdevkota.cinevault.data.SourceEntity
import com.dineshdevkota.cinevault.family.FamilyPolicy
import com.dineshdevkota.cinevault.family.FolderAccess
import com.dineshdevkota.cinevault.family.HouseholdProfile
import com.dineshdevkota.cinevault.playback.SmbDataSource
import java.io.IOException
import java.net.InetAddress
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import okio.Buffer
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class EmbyAndroidIntegrationTest {
    @Test
    fun tlsCatalogAndKeystoreRestoreRenderASeekWithAnExplicitViewerGrant() = runBlocking<Unit> {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val sample = InstrumentationRegistry.getInstrumentation().context.assets.open("playback.mp4").use { it.readBytes() }
        val certificate = HeldCertificate.Builder().commonName("Emby fixture").addSubjectAlternativeName("127.0.0.1").build()
        val serverCertificates = HandshakeCertificates.Builder().heldCertificate(certificate).build()
        val fixtureTrust = HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        val http = OkHttpClient.Builder()
            .sslSocketFactory(fixtureTrust.sslSocketFactory(), fixtureTrust.trustManager)
            .followRedirects(false).followSslRedirects(false).build()
        val server = MockWebServer()
        server.useHttps(serverCertificates.sslSocketFactory(), false)
        server.dispatcher = Fixture(sample)
        server.start(InetAddress.getByName("127.0.0.1"), 0)
        val database = Room.inMemoryDatabaseBuilder(context, CineVaultDatabase::class.java).build()
        try {
            val endpoint = server.url("/emby/").newBuilder().host("127.0.0.1").build().toString()
            val client = EmbyClient(endpoint, "fixture-android", "fixture", http)
            val account = client.signIn("fixture", "fixture-password")
            val library = client.libraries(account).single()
            val secrets = SecretBox()
            val sealed = secrets.encrypt(account.AccessToken)
            assertNotEquals(account.AccessToken, sealed)
            val source = SourceEntity(name = library.Name, host = endpoint, share = library.Id,
                username = account.User.Id, encryptedPassword = sealed, sourceType = EMBY)
            database.sources().upsert(source)
            assertEquals(1 to 1, importEmbyLibrary(database, source, secrets, http))
            val movie = database.movies().forSource(source.id).single()
            assertEquals("Approved Emby movie", movie.title)
            assertTrue(movie.certificationFetched)
            val restored = checkNotNull(database.sources().get(source.id)).embyConnection(secrets, http)
            assertEquals(account.AccessToken, restored.account.AccessToken)
            val stream = restored.client.directPlayback(restored.account, checkNotNull(embyItemId(movie.filePath)), setOf("mp4"))
            val first = restored.client.read(restored.account, stream, 0, 16)
            assertArrayEquals(sample.copyOfRange(0, 16), first.bytes)
            val viewer = HouseholdProfile("viewer", "Viewer", movieLimit = "PG")
            val allowed = viewer.copy(folders = listOf(FolderAccess(source.id, "")))
            val current = AtomicReference(viewer)
            assertFalse(FamilyPolicy.allows(viewer, movie))
            assertTrue(FamilyPolicy.allows(allowed, movie))
            assertFalse(FamilyPolicy.allows(allowed.copy(movieLimit = "G"), movie))
            val authorizer = {
                if (!FamilyPolicy.allows(current.get(), movie)) throw IOException("Viewer access denied.")
            }
            val dataSource = DataSource.Factory {
                SmbDataSource(authorize = authorizer) { EmbyVideo(restored, stream, first.totalLength, authorizer) }
            }
            val uri = Uri.parse("emby-read://fixture/movie")
            assertDenied(dataSource, uri)
            current.set(allowed)
            val shifted = dataSource.createDataSource()
            try {
                val spec = DataSpec.Builder().setUri(uri).setPosition(2048).setLength(17).build()
                shifted.open(spec)
                val bytes = ByteArray(16)
                assertEquals(16, shifted.read(bytes, 0, bytes.size))
                assertArrayEquals(sample.copyOfRange(2048, 2064), bytes)
                current.set(viewer)
                assertThrows(IOException::class.java) { shifted.read(ByteArray(1), 0, 1) }
            } finally {
                shifted.close()
            }
            current.set(allowed)
            verifyRenderedSeek(ProgressiveMediaSource.Factory(dataSource), uri)
            current.set(viewer)
            assertDenied(dataSource, uri)
            restored.client.signOut(restored.account)
        } finally {
            database.close()
            server.close()
        }
    }

    @Test
    fun negotiatedHlsFallbackRendersAndSeeksWithoutQueryToken() = runBlocking<Unit> {
        val assets = InstrumentationRegistry.getInstrumentation().context.assets
        val segments = assets.open("emby-hls-synthetic.txt").bufferedReader().useLines { lines ->
            lines.map { java.util.Base64.getDecoder().decode(it) }.toList()
        }
        assertEquals(4, segments.size)
        val certificate = HeldCertificate.Builder().commonName("Emby fixture").addSubjectAlternativeName("127.0.0.1").build()
        val serverCertificates = HandshakeCertificates.Builder().heldCertificate(certificate).build()
        val fixtureTrust = HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        val http = OkHttpClient.Builder().sslSocketFactory(fixtureTrust.sslSocketFactory(), fixtureTrust.trustManager)
            .followRedirects(false).followSslRedirects(false).build()
        val server = MockWebServer()
        server.useHttps(serverCertificates.sslSocketFactory(), false)
        val cleaned = AtomicLong()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val endpoint = request.requestUrl ?: return MockResponse().setResponseCode(400)
                if (request.getHeader("X-Emby-Token") != "fixture-token" || endpoint.queryParameter("api_key") != null) {
                    return MockResponse().setResponseCode(401)
                }
                return when (endpoint.encodedPath) {
                    "/emby/Items/movie/PlaybackInfo" -> if (request.method == "GET") MockResponse().setBody(
                        """{"PlaySessionId":"direct","MediaSources":[{"Id":"source","Container":"mkv","SupportsDirectPlay":true,"MediaStreams":[{"Type":"Video","Codec":"mpeg2video"}]}]}"""
                    ) else MockResponse().setBody(
                        """{"PlaySessionId":"transcode","MediaSources":[{"Id":"source","TranscodingUrl":"/videos/movie/master.m3u8?api_key=fixture-token"}]}"""
                    )
                    "/emby/videos/movie/master.m3u8" -> MockResponse().setBody(
                        "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=160000,CODECS=\"avc1.42c00b\"\nmain.m3u8\n"
                    )
                    "/emby/videos/movie/main.m3u8" -> MockResponse().setBody(buildString {
                        append("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n#EXT-X-PLAYLIST-TYPE:VOD\n")
                        for (index in segments.indices) append("#EXTINF:2.000,\nhls1/main/$index.ts\n")
                        append("#EXT-X-ENDLIST\n")
                    })
                    "/emby/Videos/ActiveEncodings" -> {
                        if (request.method != "DELETE" || endpoint.queryParameter("PlaySessionId") != "transcode") {
                            MockResponse().setResponseCode(400)
                        } else { cleaned.incrementAndGet(); MockResponse().setResponseCode(204) }
                    }
                    else -> {
                        val index = endpoint.encodedPath.substringAfterLast('/').removeSuffix(".ts").toIntOrNull()
                        val segment = index?.let(segments::getOrNull) ?: return MockResponse().setResponseCode(404)
                        MockResponse().setBody(Buffer().write(segment))
                    }
                }
            }
        }
        server.start(InetAddress.getByName("127.0.0.1"), 0)
        try {
            val endpoint = server.url("/emby/").newBuilder().host("127.0.0.1").build().toString()
            val client = EmbyClient(endpoint, "fixture-device", "1.0", http)
            val account = EmbyClient.Account("fixture-token", EmbyClient.User("viewer", "Viewer"))
            assertNull(client.directPlaybackIfSupported(account, "movie", setOf("mkv"), setOf("h264")))
            val session = client.transcode(account, "movie")
            val familyAllows = AtomicReference(true)
            val uri = Uri.parse(session.manifest.toString())
            val factory = DataSource.Factory {
                EmbyHlsDataSource(EmbyConnection(client, account), session) {
                    if (!familyAllows.get()) throw IOException("Viewer access denied.")
                }
            }
            try {
                assertFalse(uri.toString().contains("fixture-token"))
                verifyRenderedSeek(HlsMediaSource.Factory(factory), uri)
                val opened = factory.createDataSource()
                try {
                    opened.open(DataSpec(uri))
                    familyAllows.set(false)
                    val unchanged = ByteArray(4) { 0x2a }
                    assertThrows(IOException::class.java) { opened.read(unchanged, 0, unchanged.size) }
                    assertArrayEquals(ByteArray(4) { 0x2a }, unchanged)
                } finally { opened.close() }
                assertDenied(factory, uri)
            } finally {
                client.stopTranscode(account, session)
            }
            assertEquals(1L, cleaned.get())
        } finally {
            server.close()
        }
    }

    private fun assertDenied(factory: DataSource.Factory, uri: Uri) {
        factory.createDataSource().let { source ->
            try { assertThrows(IOException::class.java) { source.open(DataSpec(uri)) } }
            finally { source.close() }
        }
    }

    private suspend fun verifyRenderedSeek(mediaSourceFactory: MediaSource.Factory, uri: Uri) {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            var player: ExoPlayer? = null
            var view: PlayerView? = null
            val observation = PlaybackObservation()
            try {
                scenario.onActivity { activity ->
                    val exo = ExoPlayer.Builder(activity, DefaultRenderersFactory(activity).setEnableDecoderFallback(true))
                        .setMediaSourceFactory(mediaSourceFactory)
                        .build()
                    player = exo
                    exo.addListener(observation)
                    exo.setVideoFrameMetadataListener { timeUs, _, _, _ -> observation.frameTimeUs.set(timeUs) }
                    view = PlayerView(activity).apply {
                        useController = false
                        this.player = exo
                    }
                    activity.setContentView(view)
                    exo.setMediaItem(MediaItem.fromUri(uri))
                    exo.prepare()
                    exo.play()
                }
                val exo = checkNotNull(player)
                awaitPlayback(exo, observation, 500)
                withContext(Dispatchers.Main) {
                    assertTrue(exo.isCurrentMediaItemSeekable)
                    exo.seekTo(5_000)
                }
                awaitPlayback(exo, observation, 5_500)
                withContext(Dispatchers.Main) { assertTrue(observation.seekObserved) }
            } finally {
                withContext(NonCancellable + Dispatchers.Main) {
                    view?.player = null
                    player?.release()
                }
            }
        }
    }

    private suspend fun awaitPlayback(player: ExoPlayer, observation: PlaybackObservation, position: Long) {
        val reached = withTimeoutOrNull(30_000) {
            while (true) {
                if (withContext(Dispatchers.Main) {
                    observation.error?.let { throw AssertionError("Emby playback failed: ${it.errorCodeName}") }
                    observation.firstFrame && player.isPlaying && player.currentPosition >= position &&
                        observation.frameTimeUs.get() >= position * 1_000
                }) return@withTimeoutOrNull true
                delay(100)
            }
            @Suppress("UNREACHABLE_CODE")
            false
        } ?: false
        assertTrue("Emby playback never reached $position ms.", reached)
    }

    private class PlaybackObservation : Player.Listener {
        val frameTimeUs = AtomicLong(-1)
        var firstFrame = false
        var seekObserved = false
        var error: PlaybackException? = null
        override fun onRenderedFirstFrame() { firstFrame = true }
        override fun onPlayerError(error: PlaybackException) { this.error = error }
        override fun onPositionDiscontinuity(oldPosition: Player.PositionInfo, newPosition: Player.PositionInfo, reason: Int) {
            if (reason == Player.DISCONTINUITY_REASON_SEEK) seekObserved = true
        }
    }

    private class Fixture(private val sample: ByteArray) : Dispatcher() {
        override fun dispatch(request: RecordedRequest): MockResponse {
            val path = request.requestUrl?.encodedPath
            if (path == "/emby/Users/AuthenticateByName" && request.method == "POST") {
                return MockResponse().setBody("""{"AccessToken":"fixture-token","User":{"Id":"fixture-user","Name":"Fixture"}}""")
            }
            if (request.getHeader("X-Emby-Token") != "fixture-token") return MockResponse().setResponseCode(401)
            return when (path) {
                "/emby/Users/fixture-user/Views" -> MockResponse()
                    .setBody("""{"Items":[{"Id":"fixture-library","Name":"Movies","Type":"CollectionFolder"}]}""")
                "/emby/Users/fixture-user/Items" -> MockResponse().setBody("""
                    {"Items":[{"Id":"fixture-movie","Name":"Approved Emby movie","Type":"Movie","OfficialRating":"PG"}],"TotalRecordCount":1}
                    """.trimIndent())
                "/emby/Items/fixture-movie/PlaybackInfo" -> MockResponse()
                    .setBody("""{"PlaySessionId":"fixture-session","MediaSources":[{"Id":"fixture-source","Container":"mp4","SupportsDirectPlay":true}]}""")
                "/emby/Videos/fixture-movie/stream" -> range(request)
                "/emby/Sessions/Logout" -> MockResponse().setResponseCode(204)
                else -> MockResponse().setResponseCode(404)
            }
        }

        private fun range(request: RecordedRequest): MockResponse {
            val interval = request.getHeader("Range")?.removePrefix("bytes=")?.split('-').orEmpty()
            val first = interval.getOrNull(0)?.toIntOrNull() ?: -1
            val last = interval.getOrNull(1)?.toIntOrNull() ?: -1
            if (first !in sample.indices || last !in first until sample.size ||
                request.requestUrl?.queryParameter("Static") != "true") return MockResponse().setResponseCode(416)
            return MockResponse().setResponseCode(206)
                .addHeader("Content-Range", "bytes $first-$last/${sample.size}")
                .setBody(Buffer().write(sample, first, last - first + 1))
        }
    }
}
