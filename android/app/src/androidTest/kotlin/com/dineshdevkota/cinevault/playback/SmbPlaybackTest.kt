package com.dineshdevkota.cinevault.playback

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import android.util.Base64
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.extractor.DefaultExtractorsFactory
import androidx.media3.ui.PlayerView
import androidx.room.Room
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.dineshdevkota.cinevault.MainActivity
import com.dineshdevkota.cinevault.cloud.DROPBOX
import com.dineshdevkota.cinevault.cloud.DropboxClient
import com.dineshdevkota.cinevault.cloud.DropboxMedia
import com.dineshdevkota.cinevault.cloud.DriveDocument
import com.dineshdevkota.cinevault.cloud.DriveDocumentAccess
import com.dineshdevkota.cinevault.cloud.DriveDocumentGrant
import com.dineshdevkota.cinevault.cloud.DriveDocumentPath
import com.dineshdevkota.cinevault.cloud.GOOGLE_DRIVE_DOCUMENTS
import com.dineshdevkota.cinevault.cloud.GoogleDriveDocuments
import com.dineshdevkota.cinevault.cloud.GoogleDriveDocumentsException
import com.dineshdevkota.cinevault.data.CineVaultDatabase
import com.dineshdevkota.cinevault.data.SecretBox
import com.dineshdevkota.cinevault.data.SourceEntity
import com.dineshdevkota.cinevault.family.FamilyStore
import com.dineshdevkota.cinevault.family.FolderAccess
import com.dineshdevkota.cinevault.family.HouseholdProfile
import com.dineshdevkota.cinevault.library.LibraryScanner
import com.dineshdevkota.cinevault.photos.NasPhotoLoader
import com.dineshdevkota.cinevault.photos.photoAlbums
import com.dineshdevkota.cinevault.smb.RemoteHandle
import com.dineshdevkota.cinevault.smb.SmbService
import com.dineshdevkota.cinevault.smb.SourceConfig
import com.dineshdevkota.cinevault.webdav.WebDavException
import com.dineshdevkota.cinevault.webdav.WebDavMedia
import com.dineshdevkota.cinevault.webdav.WebDavService
import java.io.ByteArrayInputStream
import java.io.IOException
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
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
    fun googleDriveFolderImportPhotosCaptionsAndSeekRequireAnExplicitHouseholdGrant() = runBlocking<Unit> {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val fixture = DriveFixture()
        val drive = GoogleDriveDocuments(fixture, DriveFixture.AUTHORITY)
        val service = SmbService(fileSources = mapOf(GOOGLE_DRIVE_DOCUMENTS to drive))
        val familyPreferences = "drive-fixture-${UUID.randomUUID()}"
        val secrets = SecretBox(context)
        val family = FamilyStore(context, secrets, familyPreferences)
        val source = SourceEntity(
            name = "Drive fixture", host = "google-drive", share = "selected", username = "android-documents",
            encryptedPassword = secrets.encrypt(DriveDocumentGrant(tree = fixture.tree.toString()).encode()),
            sourceType = GOOGLE_DRIVE_DOCUMENTS,
        )
        val config = source.config(secrets)
        val database = Room.inMemoryDatabaseBuilder(context, CineVaultDatabase::class.java).build()
        try {
            database.sources().upsert(source)
            val scanner = LibraryScanner(database, secrets, service::scanVideos, scanWithProgress = service::scanMedia)
            scanner.scan(source.id)
            val films = database.movies().forSource(source.id)
            assertEquals(2, films.size)
            val movie = films.single { !it.isPhoto }
            val photo = films.single { it.isPhoto }
            assertEquals("Fixture Film (2026).mp4", movie.fileName)
            assertEquals("Movies/Fixture Film (2026).mp4", DriveDocumentPath.displayPath(movie.filePath))
            val folder = movie.filePath.substringBeforeLast('/')
            assertEquals("Movies", service.listEntries(config).single().takeIf { it.isDirectory }?.name)
            assertEquals(setOf(fixture.movie.name, fixture.photo.name, fixture.caption.name),
                service.listEntries(config.copy(rootPath = folder)).map { it.name }.toSet())
            assertTrue(runCatching { service.listEntries(config.copy(rootPath = folder.replace("Movies", "movies"))) }
                .exceptionOrNull() is GoogleDriveDocumentsException)
            assertEquals("Movies", photoAlbums(listOf(photo), listOf(source)).single().title)
            fixture.movie = fixture.movie.copy(name = "Renamed Fixture (2026).mp4")
            scanner.scan(source.id)
            val renamed = checkNotNull(database.movies().get(movie.id))
            assertEquals("Renamed Fixture (2026).mp4", renamed.fileName)
            assertTrue(!renamed.isMissing)
            assertEquals(2, database.movies().forSource(source.id).size)
            fixture.caption = fixture.caption.copy(name = "Renamed Fixture (2026).en.srt")

            family.setup("123456", "123456")
            assertNull(family.unlock(HouseholdProfile.ADMIN, "123456"))
            val viewer = HouseholdProfile("viewer", "Viewer")
            family.saveProfile(viewer, null)
            assertNull(family.unlock(viewer.id, ""))
            val authorize = {
                if (!family.permits(renamed)) throw IOException("Viewer access denied.")
            }
            val photos = NasPhotoLoader(context, database, secrets, smb = service, family = family)
            val file = SmbDataSource(authorize) { service.open(config, renamed.filePath) }
            assertTrue(runCatching { photos.load(photo.id) }.isFailure)
            assertTrue(runCatching { service.readSubtitleSidecars(config, renamed.filePath, "en", authorize) }.isFailure)
            assertTrue(runCatching { file.open(DataSpec(PlayerActivity.filePlaybackUri(config, renamed.filePath))) }.isFailure)
            file.close()
            assertEquals(0, fixture.reads)

            assertNull(family.unlock(HouseholdProfile.ADMIN, "123456"))
            family.saveProfile(viewer.copy(folders = listOf(FolderAccess(source.id, "", caseSensitive = true))), null)
            assertNull(family.unlock(viewer.id, ""))
            val captions = service.readSubtitleSidecars(config, renamed.filePath, "en", authorize).files
            assertEquals(1, captions.size)
            assertTrue(captions.single().bytes.decodeToString().contains("Synthetic Drive caption"))
            assertEquals(96, photos.load(photo.id).width)
            Media3FixturePlayback.verify(PlayerActivity.filePlaybackUri(config, renamed.filePath), authorize) { service.open(config, renamed.filePath) }
            family.lock()
            assertTrue(runCatching { photos.load(photo.id) }.isFailure)
            photos.clearMemory()
        } finally {
            context.deleteSharedPreferences(familyPreferences)
            database.close()
        }
    }

    @Test
    fun googleDriveExplicitDocumentsCannotReadAnUnselectedFile() = runBlocking<Unit> {
        val fixture = DriveFixture()
        val drive = GoogleDriveDocuments(fixture, DriveFixture.AUTHORITY)
        val allowed = DocumentsContract.buildDocumentUri(DriveFixture.AUTHORITY, fixture.movie.id)
        fixture.grants += allowed
        val config = SourceConfig("fixture", "google-drive", null, "selected", "", "android-documents",
            DriveDocumentGrant(documents = listOf(allowed.toString())).encode(), sourceType = GOOGLE_DRIVE_DOCUMENTS)
        val catalog = drive.scan(config) {}
        assertEquals(listOf(fixture.movie.id), catalog.map { DriveDocumentPath.fileID(it.path) })
        val other = DriveDocumentPath.child(DriveDocumentPath.ROOT, fixture.photo.id, fixture.photo.name)
        assertTrue(runCatching { drive.open(config, other).close() }.exceptionOrNull() is GoogleDriveDocumentsException)
        assertEquals(fixture.movie.name, drive.listEntries(config).single().takeUnless { it.isDirectory }?.name)
        assertTrue(runCatching { drive.listEntries(config.copy(rootPath = other)) }.exceptionOrNull() is GoogleDriveDocumentsException)
        assertEquals(0, fixture.reads)
    }

    private class DriveFixture : DriveDocumentAccess {
        private val assets = InstrumentationRegistry.getInstrumentation().context.assets
        private val video = assets.open("playback.mp4").use { it.readBytes() }
        private val picture = assets.open("Photos/01.jpg").use { it.readBytes() }
        private val cue = "1\n00:00:00,100 --> 00:00:02,500\nSynthetic Drive caption\n".encodeToByteArray()
        val tree = DocumentsContract.buildTreeDocumentUri(AUTHORITY, "root")
        val grants = mutableSetOf(tree)
        private val root = DriveDocument("root", "Drive fixture", DocumentsContract.Document.MIME_TYPE_DIR, 0)
        private val folder = DriveDocument("folder", "Movies", root.mime, 0)
        var movie = DriveDocument("movie", "Fixture Film (2026).mp4", "video/mp4", 64L * 1024 * 1024)
        val photo = DriveDocument("photo", "Still.jpg", "image/jpeg", picture.size.toLong())
        var caption = DriveDocument("caption", "Fixture Film (2026).en.srt", "application/x-subrip", cue.size.toLong())
        var reads = 0
            private set

        override fun hasGrant(uri: Uri): Boolean = uri in grants
        override fun document(uri: Uri): DriveDocument =
            listOf(root, folder, movie, photo, caption).single { it.id == DocumentsContract.getDocumentId(uri) }
        override fun children(uri: Uri): List<DriveDocument> = when (DocumentsContract.getDocumentId(uri)) {
            root.id -> listOf(folder)
            folder.id -> listOf(movie, photo, caption)
            else -> emptyList()
        }

        override fun open(uri: Uri, size: Long): RemoteHandle {
            reads++
            val payload = when (DocumentsContract.getDocumentId(uri)) {
                movie.id -> video
                photo.id -> picture
                caption.id -> cue
                else -> error("Unexpected Drive fixture document.")
            }
            return object : RemoteHandle {
                override val length = payload.size.toLong()
                override fun stream(position: Long): ByteArrayInputStream =
                    ByteArrayInputStream(payload, position.toInt(), payload.size - position.toInt())
                override fun close() = Unit
            }
        }

        companion object { const val AUTHORITY = "fixture.drive.documents" }
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
                    val files = DataSource.Factory { SmbDataSource(authorize = authorize, openFile = openFile) }
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
