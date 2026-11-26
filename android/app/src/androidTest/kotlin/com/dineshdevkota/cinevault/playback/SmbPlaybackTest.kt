package com.dineshdevkota.cinevault.playback

import android.net.Uri
import android.util.Base64
import android.content.Context
import androidx.room.Room
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.DataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.extractor.DefaultExtractorsFactory
import androidx.media3.ui.PlayerView
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.dineshdevkota.cinevault.MainActivity
import com.dineshdevkota.cinevault.cloud.DROPBOX
import com.dineshdevkota.cinevault.cloud.DropboxClient
import com.dineshdevkota.cinevault.cloud.DropboxMedia
import com.dineshdevkota.cinevault.data.CineVaultDatabase
import com.dineshdevkota.cinevault.data.SecretBox
import com.dineshdevkota.cinevault.data.SourceEntity
import com.dineshdevkota.cinevault.family.FamilyStore
import com.dineshdevkota.cinevault.family.FolderAccess
import com.dineshdevkota.cinevault.family.HouseholdProfile
import com.dineshdevkota.cinevault.library.LibraryScanner
import com.dineshdevkota.cinevault.photos.NasPhotoLoader
import com.dineshdevkota.cinevault.smb.RemoteHandle
import com.dineshdevkota.cinevault.smb.SmbService
import com.dineshdevkota.cinevault.smb.SourceConfig
import com.dineshdevkota.cinevault.webdav.WebDavException
import com.dineshdevkota.cinevault.webdav.WebDavMedia
import com.dineshdevkota.cinevault.webdav.WebDavService
import java.security.KeyStore
import java.security.cert.CertificateFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.OkHttpClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/** Decodes and seeks the fixture movie through the app's file-backed Media3 data source. */
@RunWith(AndroidJUnit4::class)
class SmbPlaybackTest {
    @Test
    fun playbackAndSeekStreamTheScannedMovie() = runBlocking {
        val host = InstrumentationRegistry.getArguments().getString("nasHost")
        assumeTrue("Pass nasHost to run SMB playback", !host.isNullOrBlank())
        val config = SourceConfig(UUID.randomUUID().toString(), host!!, 1445, "CINEVAULT", "Movies", "cinevault", "fixture-only")
        val smb = SmbService()
        try {
            val movie = smb.scanVideos(config).single()
            Media3FixturePlayback.verify(PlayerActivity.filePlaybackUri(config, movie.path)) { smb.open(config, movie.path) }
        } finally {
            smb.reset(config.id)
        }
    }

    @Test
    fun mkvPlaybackAndSeekFromNas() = runBlocking {
        val host = requireNotNull(InstrumentationRegistry.getArguments().getString("nasHost"))
        val config = SourceConfig(UUID.randomUUID().toString(), host, 1445, "FORMATPLAYBACK", "", "cinevault", "fixture-only")
        val smb = SmbService()
        try {
            assertTrue("The production media scan must discover the MKV fixture",
                smb.scanMedia(config) {}.any { it.path == "Feature.mkv" })
            Media3FixturePlayback.verify(PlayerActivity.filePlaybackUri(config, "Feature.mkv")) { smb.open(config, "Feature.mkv") }
        } finally { smb.reset(config.id) }
    }

    @Test
    fun webDavAuthenticationScanPlaybackAndSeek() = runBlocking {
        val fixtureCertificate = InstrumentationRegistry.getArguments().getString("webDavCertificate")
        assumeTrue("Pass webDavCertificate to run the disposable WebDAV fixture.", !fixtureCertificate.isNullOrBlank())
        val http = fixtureClient(checkNotNull(fixtureCertificate)).build()
        val provider = WebDavMedia(WebDavService(http))
        val config = SourceConfig(
            UUID.randomUUID().toString(), "https://10.0.2.2:15443/dav/", null, "", "Movies",
            "cinevault", "fixture-only", sourceType = "webdav",
        )
        try {
            provider.service.list(config.copy(password = "invalid"))
            fail("The fixture must reject incorrect credentials")
        } catch (error: WebDavException) {
            assertEquals(401, error.status)
        }
        val movie = provider.scan(config) {}.single()
        assertEquals("Movies/Film.mp4", movie.path)
        assertEquals("https://10.0.2.2:15443/dav/Movies/Film.mp4", PlayerActivity.filePlaybackUri(config, movie.path).toString())
        val captions = provider.subtitles(config, movie.path, "en")
        assertEquals(1, captions.files.size)
        Media3FixturePlayback.verify(PlayerActivity.filePlaybackUri(config, movie.path)) { provider.service.open(config, movie.path) }
    }

    @Test
    fun dropboxApprovalImportPlaybackSeekPhotosAndHouseholdGate() = runBlocking {
        val certificate = InstrumentationRegistry.getArguments().getString("dropboxCertificate")
        assumeTrue("Pass dropboxCertificate to run the disposable Dropbox fixture.", !certificate.isNullOrBlank())
        val contentReads = AtomicInteger()
        val refreshes = AtomicInteger()
        val http = fixtureClient(checkNotNull(certificate)).addInterceptor { chain ->
            val request = chain.request()
            assertTrue("Only the official Dropbox endpoints are routed to the fixture.",
                request.url.host in setOf("api.dropboxapi.com", "content.dropboxapi.com"))
            if (request.url.encodedPath == "/2/files/download") contentReads.incrementAndGet()
            if ((request.body as? okhttp3.FormBody)?.let { body ->
                    (0 until body.size).any { body.name(it) == "grant_type" && body.value(it) == "refresh_token" }
                } == true) refreshes.incrementAndGet()
            val local = request.url.newBuilder().host("10.0.2.2").port(18444).build()
            chain.proceed(request.newBuilder().url(local).build())
        }.build()
        val client = DropboxClient("fixture-app", http)
        val approval = client.beginAuthorization()
        assertNull(approval.url.queryParameter("redirect_uri"))
        try {
            client.completeAuthorization(approval, "wrong")
            fail("The fixture must reject an incorrect authorization code.")
        } catch (error: com.dineshdevkota.cinevault.cloud.CloudClientException) {
            assertEquals(400, error.statusCode)
        }
        val credentials = client.completeAuthorization(approval, "fixture-code")
        val refresh = requireNotNull(credentials.refreshToken)
        val selected = client.metadata("/Media", credentials.accessToken)
        val context = ApplicationProvider.getApplicationContext<Context>()
        val secrets = SecretBox(context)
        val media = DropboxMedia(http)
        val profilePreferences = "dropbox-test-${UUID.randomUUID()}"
        val family = FamilyStore(context, secrets, profilePreferences)
        val database = Room.inMemoryDatabaseBuilder(context, CineVaultDatabase::class.java).build()
        val loader = NasPhotoLoader(context, database, secrets, family = family, openDropbox = media::open)
        try {
            val source = SourceEntity(name = "Fixture Dropbox", host = "fixture-app", share = requireNotNull(selected.id),
                rootPath = requireNotNull(selected.displayPath).removePrefix("/"), username = requireNotNull(credentials.accountId),
                encryptedPassword = secrets.encrypt(refresh), sourceType = DROPBOX)
            assertNotEquals(refresh, source.encryptedPassword)
            database.sources().upsert(source)
            val scanner = LibraryScanner(database, secrets, { error("Only the paginated route should be used.") },
                scanWithProgress = media::scan)
            scanner.scan(source.id)
            val catalog = database.movies().forSource(source.id)
            assertEquals(setOf("Media/Films/Film.mp4", "Media/Photos/Family.jpg"), catalog.map { it.filePath }.toSet())
            val movie = catalog.single { !it.isPhoto }
            val photo = catalog.single { it.isPhoto }
            val config = source.config(secrets)
            assertTrue(refreshes.get() > 0)
            assertEquals(0, contentReads.get())

            family.setup("123456", "123456")
            assertNull(family.unlock(HouseholdProfile.ADMIN, "123456"))
            val viewer = HouseholdProfile("dropbox-viewer", "Viewer")
            family.saveProfile(viewer, null)
            assertNull(family.unlock(viewer.id, ""))
            suspend fun checkNoPhoto() {
                try { loader.load(photo.id); fail("A viewer without permission decoded the photo.") }
                catch (_: IllegalStateException) { }
            }
            checkNoPhoto()
            try {
                media.open(config, movie.filePath) { check(family.permits(movie)) }.close()
                fail("The viewer opened a movie without a grant.")
            } catch (_: IllegalStateException) { }
            assertEquals(0, contentReads.get())

            assertNull(family.unlock(HouseholdProfile.ADMIN, "123456"))
            family.saveProfile(viewer.copy(folders = listOf(FolderAccess(source.id, "Media"))), null)
            assertNull(family.unlock(viewer.id, ""))
            val session = family.current
            val authorize = { check(family.isCurrent(session) && family.permits(movie)) }
            val captions = media.subtitles(config, movie.filePath, "en", authorize)
            assertEquals("Media/Films/film.en.srt", captions.files.single().match.path)
            assertTrue(captions.files.single().bytes.decodeToString().contains("Dropbox fixture caption."))
            assertTrue(loader.load(photo.id).width > 0)
            Media3FixturePlayback.verify(PlayerActivity.filePlaybackUri(config, movie.filePath), authorize) { media.open(config, movie.filePath, authorize) }
            media.open(config, movie.filePath, authorize).use { handle ->
                handle.stream(8_000).use { stream ->
                    assertTrue(stream.read() >= 0)
                    val received = contentReads.get()
                    family.lock()
                    try { stream.read(); fail("The old viewer read buffered media after locking.") }
                    catch (_: IllegalStateException) { }
                    assertEquals(received, contentReads.get())
                }
            }
            checkNoPhoto()
        } finally {
            loader.clearMemory()
            context.deleteSharedPreferences(profilePreferences)
            database.close()
            client.revoke(credentials.accessToken)
        }
    }

    private fun fixtureClient(encodedCertificate: String): OkHttpClient.Builder {
        val certificate = Base64.decode(encodedCertificate, Base64.DEFAULT).inputStream().use {
            CertificateFactory.getInstance("X.509").generateCertificate(it)
        }
        val trust = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
            load(null, null)
            setCertificateEntry("tls-fixture", certificate)
        }
        val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(trust) }
        val manager = factory.trustManagers.filterIsInstance<X509TrustManager>().single()
        val tls = SSLContext.getInstance("TLS").apply { init(null, arrayOf(manager), null) }
        return OkHttpClient.Builder().sslSocketFactory(tls.socketFactory, manager)
            .followRedirects(false).followSslRedirects(false)
    }

}

internal object Media3FixturePlayback {
    suspend fun verify(uri: Uri, authorize: () -> Unit = {}, openFile: () -> RemoteHandle) {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            var player: ExoPlayer? = null
            var view: PlayerView? = null
            val observation = PlaybackObservation()
            try {
                scenario.onActivity { activity ->
                    val files = DataSource.Factory { SmbDataSource(authorize, openFile) }
                    val sources = ProgressiveMediaSource.Factory(
                        files, DefaultExtractorsFactory().setConstantBitrateSeekingEnabled(true),
                    ).setLoadErrorHandlingPolicy(SmbDataSource.loadErrorPolicy)
                    val exo = ExoPlayer.Builder(activity, DefaultRenderersFactory(activity).setEnableDecoderFallback(true))
                        .setMediaSourceFactory(sources)
                        .build()
                    player = exo
                    exo.addListener(observation)
                    // This callback is on the playback thread; all other observations are on Main.
                    exo.setVideoFrameMetadataListener { presentationTimeUs, _, _, _ ->
                        observation.frameTimeUs.set(presentationTimeUs)
                    }
                    view = PlayerView(activity).apply {
                        useController = false
                        keepScreenOn = true
                        this.player = exo
                    }
                    // An actual attached SurfaceView exercises decoding/rendering on the emulator.
                    activity.setContentView(view)
                    exo.setMediaItem(MediaItem.fromUri(uri))
                    exo.prepare()
                    exo.play()
                }
                val exo = checkNotNull(player)
                awaitPlayback(exo, observation, positionMs = 500)
                withContext(Dispatchers.Main) {
                    assertTrue("The scanned movie must expose a seekable timeline", exo.isCurrentMediaItemSeekable)
                    exo.seekTo(8_000)
                    exo.play()
                }
                awaitPlayback(exo, observation, positionMs = 8_500)
                withContext(Dispatchers.Main) {
                    assertTrue("Media3 must acknowledge the requested seek", observation.seekObserved)
                    observation.throwIfFailed()
                }
            } finally {
                withContext(NonCancellable + Dispatchers.Main) {
                    view?.player = null
                    player?.release()
                }
            }
        }
    }

    private suspend fun awaitPlayback(player: ExoPlayer, observation: PlaybackObservation, positionMs: Long) {
        var snapshot = "Player not observed"
        val advanced = withTimeoutOrNull(40_000) {
            while (true) {
                val reached = withContext(Dispatchers.Main) {
                    observation.throwIfFailed()
                    val frameUs = observation.frameTimeUs.get()
                    snapshot = "state=${player.playbackState}, playing=${player.isPlaying}, " +
                        "position=${player.currentPosition}, videoFrameUs=$frameUs, firstFrame=${observation.firstFrame}"
                    observation.firstFrame && player.isPlaying && player.currentPosition >= positionMs &&
                        frameUs >= positionMs * 1_000
                }
                if (reached) return@withTimeoutOrNull true
                delay(100)
            }
            @Suppress("UNREACHABLE_CODE")
            false
        } ?: false
        assertTrue("Fixture playback did not advance past $positionMs ms: $snapshot", advanced)
    }

    private class PlaybackObservation : Player.Listener {
        val frameTimeUs = AtomicLong(-1)
        var firstFrame = false
        var seekObserved = false
        private var error: PlaybackException? = null

        override fun onRenderedFirstFrame() { firstFrame = true }

        override fun onPlayerError(error: PlaybackException) { this.error = error }

        override fun onPositionDiscontinuity(oldPosition: Player.PositionInfo, newPosition: Player.PositionInfo, reason: Int) {
            if (reason == Player.DISCONTINUITY_REASON_SEEK) seekObserved = true
        }

        fun throwIfFailed() {
            error?.let { throw AssertionError("Media3 failed to play the fixture: ${it.errorCodeName}", it) }
        }
    }
}
