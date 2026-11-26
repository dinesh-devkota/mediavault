@file:OptIn(UnstableApi::class)

package com.dineshdevkota.cinevault.jellyfin

import android.content.Context
import android.net.Uri
import android.util.Base64
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
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
import com.dineshdevkota.cinevault.family.FamilyStore
import com.dineshdevkota.cinevault.family.HouseholdProfile
import com.dineshdevkota.cinevault.playback.PreparedSubtitle
import com.dineshdevkota.cinevault.playback.SubtitleMediaSourceFactory
import com.dineshdevkota.cinevault.playback.SubtitleTracks
import com.dineshdevkota.cinevault.playback.jellyfinAndroidProfile
import com.dineshdevkota.cinevault.playback.jellyfinDataSources
import com.dineshdevkota.cinevault.playback.jellyfinLocalSubtitleDataSources
import java.io.IOException
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
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
import com.dineshdevkota.cinevault.photos.NasPhotoLoader
import com.dineshdevkota.cinevault.photos.photoAlbums
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Uses a disposable Jellyfin server and a test-only CA on the hosted Android TV emulator. */
@RunWith(AndroidJUnit4::class)
class JellyfinAndroidIntegrationTest {
    @Test
    fun protectedImportPlaysAndSeeksOnATvSurfaceWithAnExplicitGrant() = runBlocking<Unit> {
        val certificate = InstrumentationRegistry.getArguments().getString("jellyfinCertificate")
        assumeTrue("Run this journey on the disposable Android TV fixture.", !certificate.isNullOrBlank())
        val http = fixtureClient(checkNotNull(certificate))
        val id = UUID.randomUUID().toString()
        val endpoint = "https://10.0.2.2:18443/"
        val client = JellyfinClient(endpoint, id, "fixture", http = http)
        val session = client.signIn("fixture", "fixture-only")
        try {
            val library = client.libraries(session).single { it.name == "Fixture Movies" }
            val secrets = SecretBox(androidx.test.core.app.ApplicationProvider.getApplicationContext())
            val sealed = secrets.encrypt(session.token)
            assertNotEquals(session.token, sealed)
            val source = SourceEntity(
                id = id, name = library.name, host = endpoint, share = library.id,
                username = session.user.id, encryptedPassword = sealed, sourceType = JELLYFIN,
            )
            val database = Room.inMemoryDatabaseBuilder(
                ApplicationProvider.getApplicationContext<Context>(), CineVaultDatabase::class.java,
            ).build()
            try {
                database.sources().upsert(source)
                assertEquals(1 to 1, importJellyfinLibrary(database, source, secrets, http) {})
                val movie = database.movies().forSource(id).single()
                assertEquals(9997001, movie.tmdbId)
                assertEquals("Fixture Film (2026).mp4", movie.fileName)
                val restored = source.jellyfinConnection(secrets, http)
                assertEquals(session.token, restored.session.token)
                val stream = restored.client.playback(
                    restored.session, checkNotNull(jellyfinItemID(movie.filePath)), jellyfinAndroidProfile,
                )
                assertEquals("DirectPlay", stream.method)
                val viewer = HouseholdProfile("viewer", "Viewer")
                val allowed = viewer.copy(folders = listOf(FolderAccess(source.id, "", caseSensitive = true)))
                val current = AtomicReference(viewer)
                assertFalse(FamilyPolicy.allows(viewer, movie))
                assertTrue(FamilyPolicy.allows(allowed, movie))
                val authorize = {
                    if (!FamilyPolicy.allows(current.get(), movie)) throw IOException("Viewer access denied.")
                }
                val transport = jellyfinDataSources(restored, stream, http, authorize)
                val local = jellyfinLocalSubtitleDataSources(authorize)
                val sidecar = stream.subtitles.single()
                val remoteCaption = MediaItem.SubtitleConfiguration.Builder(Uri.parse(sidecar.url.toString()))
                    .setId("fixture-nas").setLabel("Jellyfin NAS caption")
                    .setMimeType(MimeTypes.TEXT_VTT).setLanguage(sidecar.language).build()
                val downloaded = requireNotNull(SubtitleTracks.configuration(
                    "1\n00:00:00,100 --> 00:00:10,500\nSynthetic downloaded caption\n".encodeToByteArray(),
                    MimeTypes.APPLICATION_SUBRIP, "es", "Downloaded caption", "fixture-download",
                ))
                val uri = Uri.parse(stream.url.toString())
                assertDeniedBeforeOpening(transport, uri)
                assertDeniedBeforeOpening(transport, remoteCaption.uri)
                assertDeniedBeforeOpening(local, downloaded.configuration.uri)
                current.set(allowed)
                verifyRenderedSeek(transport, uri, local, remoteCaption, downloaded)
                val hls = restored.client.playback(
                    restored.session, checkNotNull(jellyfinItemID(movie.filePath)), jellyfinAndroidProfile, allowDirect = false,
                )
                assertEquals("Transcode", hls.method)
                val hlsTransport = jellyfinDataSources(restored, hls, http, authorize)
                val hlsUri = Uri.parse(hls.url.toString())
                verifyRenderedSeek(hlsTransport, hlsUri, local, remoteCaption, downloaded, MimeTypes.APPLICATION_M3U8)
                current.set(viewer)
                assertDeniedBeforeOpening(transport, uri)
                assertDeniedBeforeOpening(hlsTransport, hlsUri)
                assertDeniedBeforeOpening(transport, remoteCaption.uri)
                assertDeniedBeforeOpening(local, downloaded.configuration.uri)
            } finally {
                database.close()
            }
        } finally {
            client.signOut(session)
        }
    }

    @Test
    fun photoAlbumAndServerArtworkDecodeOnlyForProfilesWithAccess() = runBlocking<Unit> {
        val certificate = InstrumentationRegistry.getArguments().getString("jellyfinCertificate")
        assumeTrue("Run this journey on the disposable Android TV fixture.", !certificate.isNullOrBlank())
        val requests = AtomicInteger()
        val http = fixtureClient(checkNotNull(certificate)).newBuilder().addInterceptor { chain ->
            if ("Images" in chain.request().url.pathSegments) requests.incrementAndGet()
            chain.proceed(chain.request())
        }.build()
        val id = UUID.randomUUID().toString()
        val endpoint = "https://10.0.2.2:18443/"
        val client = JellyfinClient(endpoint, id, "fixture", http = http)
        val session = client.signIn("fixture", "fixture-only")
        val context = ApplicationProvider.getApplicationContext<Context>()
        val secrets = SecretBox(androidx.test.core.app.ApplicationProvider.getApplicationContext())
        val database = Room.inMemoryDatabaseBuilder(context, CineVaultDatabase::class.java).build()
        val profilePreferences = "jellyfin-fixture-$id"
        val household = FamilyStore(context, secrets, profilePreferences)
        val photos = NasPhotoLoader(context, database, secrets, family = household, fixtureHttp = http)
        try {
            val libraries = client.libraries(session)
            suspend fun add(name: String): SourceEntity {
                val library = libraries.single { it.name == name }
                val source = SourceEntity(
                    id = UUID.randomUUID().toString(), name = name, host = endpoint, share = library.id,
                    username = session.user.id, encryptedPassword = secrets.encrypt(session.token), sourceType = JELLYFIN,
                )
                database.sources().upsert(source)
                assertEquals(1 to 1, importJellyfinLibrary(database, source, secrets, http) {})
                return source
            }
            val photoSource = add("Fixture Photos")
            val photo = database.movies().forSource(photoSource.id).single()
            val movieSource = add("Fixture Movies")
            val movie = database.movies().forSource(movieSource.id).single()
            assertEquals(photoSource.name, photoAlbums(listOf(photo), listOf(photoSource)).single().title)
            household.setup("123456", "123456")
            assertNull(household.unlock(HouseholdProfile.ADMIN, "123456"))
            assertTrue(photos.loadArtwork(movie.id, 342, JellyfinImage.Primary).width > 0)
            val viewer = HouseholdProfile("viewer", "Viewer")
            household.saveProfile(viewer, null)
            assertNull(household.unlock(viewer.id, ""))
            assertTrue(runCatching { photos.load(photo.id) }.isFailure)
            assertTrue(runCatching { photos.loadArtwork(movie.id, 342, JellyfinImage.Primary) }.isFailure)
            assertEquals(1, requests.get())
            assertNull(household.unlock(HouseholdProfile.ADMIN, "123456"))
            household.saveProfile(viewer.copy(folders = listOf(FolderAccess(photoSource.id, "", caseSensitive = true))), null)
            assertNull(household.unlock(viewer.id, ""))
            assertTrue(photos.load(photo.id).width > 0)
            assertEquals(2, requests.get())
            household.lock()
            assertTrue(runCatching { photos.load(photo.id) }.isFailure)
            assertEquals(2, requests.get())
        } finally {
            photos.clearMemory()
            context.deleteSharedPreferences(profilePreferences)
            database.close()
            client.signOut(session)
        }
    }

    private fun assertDeniedBeforeOpening(factory: DataSource.Factory, uri: Uri) {
        val connection = factory.createDataSource()
        try {
            connection.open(DataSpec(uri))
            fail("An unauthorized viewer opened a Jellyfin byte stream.")
        } catch (denied: IOException) {
            assertEquals("Viewer access denied.", denied.message)
        } finally {
            connection.close()
        }
    }

    private suspend fun verifyRenderedSeek(
        transport: DataSource.Factory, uri: Uri, local: DataSource.Factory,
        remoteCaption: MediaItem.SubtitleConfiguration, downloaded: PreparedSubtitle, mimeType: String? = null,
    ) {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            var player: ExoPlayer? = null
            var view: PlayerView? = null
            val observation = PlaybackObservation()
            try {
                scenario.onActivity { activity ->
                    val exo = ExoPlayer.Builder(activity, DefaultRenderersFactory(activity).setEnableDecoderFallback(true))
                        .setMediaSourceFactory(SubtitleMediaSourceFactory(DefaultMediaSourceFactory(transport), local) { listOf(downloaded) })
                        .build()
                    player = exo
                    exo.addListener(observation)
                    exo.setVideoFrameMetadataListener { timeUs, _, _, _ ->
                        observation.frameTimeUs.set(timeUs)
                        observation.frames.incrementAndGet()
                    }
                    view = PlayerView(activity).apply {
                        useController = false
                        this.player = exo
                    }
                    activity.setContentView(view)
                    exo.setMediaItem(MediaItem.Builder().setUri(uri).setMimeType(mimeType)
                        .setSubtitleConfigurations(listOf(remoteCaption, downloaded.configuration)).build())
                    exo.prepare()
                    exo.play()
                }
                val exo = checkNotNull(player)
                awaitPlayback(exo, observation, 500, mimeType)
                val beforeSeek = withContext(Dispatchers.Main) {
                    assertTrue("Jellyfin must expose a seekable timeline.", exo.isCurrentMediaItemSeekable)
                    val labels = exo.currentTracks.groups.filter { it.type == C.TRACK_TYPE_TEXT }
                        .flatMap { group -> (0 until group.length).map { group.getTrackFormat(it).label } }
                    assertTrue("Expected both the Jellyfin sidecar and downloaded caption.", labels.containsAll(
                        listOf("Jellyfin NAS caption", "Downloaded caption")))
                    observation.frames.get().also { exo.seekTo(5_000) }
                }
                awaitPlayback(exo, observation, 5_500, mimeType, beforeSeek)
                withContext(Dispatchers.Main) { assertTrue(observation.seekObserved) }
            } finally {
                withContext(NonCancellable + Dispatchers.Main) {
                    view?.player = null
                    player?.release()
                }
            }
        }
    }

    private suspend fun awaitPlayback(
        player: ExoPlayer, observation: PlaybackObservation, position: Long, mimeType: String?, previousFrames: Int = 0,
    ) {
        val reached = withTimeoutOrNull(30_000) {
            while (true) {
                if (withContext(Dispatchers.Main) {
                    observation.error?.let { throw AssertionError("Jellyfin playback failed: ${it.errorCodeName}") }
                    val decoded = if (mimeType == MimeTypes.APPLICATION_M3U8) observation.frames.get() > previousFrames
                        else observation.frameTimeUs.get() >= position * 1_000
                    observation.firstFrame && player.isPlaying && player.currentPosition >= position && decoded
                }) return@withTimeoutOrNull true
                delay(100)
            }
            @Suppress("UNREACHABLE_CODE")
            false
        } ?: false
        assertTrue("Jellyfin playback did not reach $position ms.", reached)
    }

    private fun fixtureClient(base64Certificate: String): OkHttpClient {
        val certificate = Base64.decode(base64Certificate, Base64.DEFAULT).inputStream().use {
            CertificateFactory.getInstance("X.509").generateCertificate(it)
        }
        val trust = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
            load(null, null)
            setCertificateEntry("jellyfin-fixture", certificate)
        }
        val manager = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(trust) }
            .trustManagers.filterIsInstance<X509TrustManager>().single()
        val tls = SSLContext.getInstance("TLS").apply { init(null, arrayOf(manager), null) }
        return OkHttpClient.Builder().sslSocketFactory(tls.socketFactory, manager)
            .followRedirects(false).followSslRedirects(false).build()
    }

    private class PlaybackObservation : Player.Listener {
        val frameTimeUs = AtomicLong(-1)
        val frames = AtomicInteger()
        var firstFrame = false
        var seekObserved = false
        var error: PlaybackException? = null
        override fun onRenderedFirstFrame() { firstFrame = true }
        override fun onPlayerError(error: PlaybackException) { this.error = error }
        override fun onPositionDiscontinuity(oldPosition: Player.PositionInfo, newPosition: Player.PositionInfo, reason: Int) {
            if (reason == Player.DISCONTINUITY_REASON_SEEK) seekObserved = true
        }
    }
}
