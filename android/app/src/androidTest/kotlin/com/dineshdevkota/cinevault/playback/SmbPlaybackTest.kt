package com.dineshdevkota.cinevault.playback

import android.util.Base64
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
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.dineshdevkota.cinevault.MainActivity
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
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID
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
            verifyPlayback(config, movie.path) { smb.open(config, movie.path) }
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
            verifyPlayback(config, "Feature.mkv") { smb.open(config, "Feature.mkv") }
        } finally { smb.reset(config.id) }
    }

    @Test
    fun webDavAuthenticationScanPlaybackAndSeek() = runBlocking {
        val fixtureCertificate = InstrumentationRegistry.getArguments().getString("webDavCertificate")
        assumeTrue("Pass webDavCertificate to run the disposable WebDAV fixture.", !fixtureCertificate.isNullOrBlank())
        val certificate = Base64.decode(checkNotNull(fixtureCertificate), Base64.DEFAULT).inputStream().use {
            CertificateFactory.getInstance("X.509").generateCertificate(it)
        }
        val trust = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
            load(null, null)
            setCertificateEntry("webdav-fixture", certificate)
        }
        val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(trust) }
        val manager = factory.trustManagers.filterIsInstance<X509TrustManager>().single()
        val tls = SSLContext.getInstance("TLS").apply { init(null, arrayOf(manager), null) }
        val http = OkHttpClient.Builder().sslSocketFactory(tls.socketFactory, manager)
            .followRedirects(false).followSslRedirects(false).build()
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
        verifyPlayback(config, movie.path) { provider.service.open(config, movie.path) }
    }

    private suspend fun verifyPlayback(config: SourceConfig, path: String, openFile: () -> RemoteHandle) {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            var player: ExoPlayer? = null
            var view: PlayerView? = null
            val observation = PlaybackObservation()
            try {
                scenario.onActivity { activity ->
                    val files = DataSource.Factory { SmbDataSource(openFile = openFile) }
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
                    exo.setMediaItem(MediaItem.fromUri(PlayerActivity.filePlaybackUri(config, path)))
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
