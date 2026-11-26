package com.dineshdevkota.cinevault.cloud

import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
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
import com.dineshdevkota.cinevault.data.saveSourceWithExclusions
import com.dineshdevkota.cinevault.family.FamilyLibrary
import com.dineshdevkota.cinevault.family.FamilyStore
import com.dineshdevkota.cinevault.family.FolderAccess
import com.dineshdevkota.cinevault.family.HouseholdProfile
import com.dineshdevkota.cinevault.library.LibraryScanner
import com.dineshdevkota.cinevault.photos.NasPhotoLoader
import com.dineshdevkota.cinevault.playback.PlayerActivity
import com.dineshdevkota.cinevault.playback.SmbDataSource
import com.dineshdevkota.cinevault.smb.SmbService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import okhttp3.FormBody
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

@RunWith(AndroidJUnit4::class)
@OptIn(UnstableApi::class)
class OneDriveMediaIntegrationTest {
    @Test
    fun stagedSignInImportsSelectedFolderAndPlaysWithBoundedReadsAndCaptions() = runBlocking {
        val fixture = GraphFixture()
        val sourceId = UUID.randomUUID()
        val store = MemoryAccountStore()
        val media = OneDriveMedia(store) { OneDriveClient(it, fixture.http) }
        val smb = SmbService(fileSources = mapOf(ONEDRIVE to media))
        val context = ApplicationProvider.getApplicationContext<Context>()
        val database = Room.inMemoryDatabaseBuilder(context, CineVaultDatabase::class.java).build()
        val profilePreferences = "onedrive-fixture-$sourceId"
        val secrets = SecretBox()
        val family = FamilyStore(context, secrets, profilePreferences)
        val library = FamilyLibrary(database, family)
        val photos = NasPhotoLoader(context, database, secrets, smb = smb, family = family)
        try {
            val account = media.account(sourceId, CLIENT_ID)
            val code = account.beginSignIn()
            assertEquals("FIXTURE", code.userCode)
            account.link(code, staged = true)
            assertNull("Approval alone must not persist new credentials", store.load(sourceId))
            val version = account.connectionVersion()
            val folder = media.childFolders(account, null, version).single()
            assertEquals("Fixture media", folder.name)
            val source = SourceEntity(id = sourceId.toString(), name = folder.name, host = CLIENT_ID, share = folder.id, sourceType = ONEDRIVE)
            account.commitLink(version)
            assertEquals("fixture-drive", store.load(sourceId)?.driveId)
            database.sources().upsert(source)
            val scanner = LibraryScanner(database, secrets, smb::scanVideos, scanWithProgress = smb::scanMedia)
            fixture.rejectFirstAccess = true
            scanner.scan(source.id)
            assertEquals("Refresh should rotate when Graph expires a cached token", "renewed", store.load(sourceId)?.refreshToken)
            val imported = database.movies().forSource(source.id)
            assertEquals(setOf("Media/Film.mp4", "Media/Cover.jpg", "Hidden/Private.mp4"), imported.map { it.filePath }.toSet())
            val movie = imported.single { it.filePath == "Media/Film.mp4" }
            val photo = imported.single { it.isPhoto }
            val config = source.config(secrets)
            assertEquals(listOf("Hidden", "Media"), media.childFolders(config, ""))
            assertTrue(runCatching { smb.open(config, "media/Film.mp4") }.isFailure)
            assertTrue(runCatching { smb.open(config, "../Film.mp4") }.isFailure)
            val captions = smb.readSubtitleSidecars(config, movie.filePath, "en").files
            assertEquals("en", captions.single().match.language)
            assertArrayEquals(fixture.captions, captions.single().bytes)

            family.setup("123456", "123456")
            assertNull(family.unlock(HouseholdProfile.ADMIN, "123456"))
            val viewer = HouseholdProfile("viewer", "Viewer")
            family.saveProfile(viewer, null)
            assertNull(family.unlock(viewer.id, ""))
            val unread = fixture.downloads.get()
            assertNull(library.get(movie.id))
            assertTrue(runCatching { photos.load(photo.id) }.isFailure)
            assertEquals(unread, fixture.downloads.get())

            assertNull(family.unlock(HouseholdProfile.ADMIN, "123456"))
            family.saveProfile(viewer.copy(folders = listOf(FolderAccess(source.id, "Media", caseSensitive = true))), null)
            assertNull(family.unlock(viewer.id, ""))
            assertNull(library.get(imported.single { it.filePath.startsWith("Hidden") }.id))
            assertTrue(photos.load(photo.id).width > 0)
            val session = family.current
            val factory = DataSource.Factory {
                SmbDataSource(
                    authorize = { check(family.isCurrent(session) && family.permits(movie)) },
                    openFile = { smb.open(config, movie.filePath) },
                )
            }
            val uri = PlayerActivity.filePlaybackUri(config, movie.filePath)
            val reader = factory.createDataSource()
            try {
                reader.open(DataSpec.Builder().setUri(uri).setPosition(8192).setLength(16).build())
                val actual = ByteArray(16)
                assertEquals(actual.size, reader.read(actual, 0, actual.size))
                assertArrayEquals(fixture.video.copyOfRange(8192, 8208), actual)
                assertEquals(8192L, fixture.lastRangeOffset.get())
            } finally { reader.close() }
            verifyPlayback(factory, uri)

            assertNull(family.unlock(HouseholdProfile.ADMIN, "123456"))
            database.saveSourceWithExclusions(source.copy(ignoredFiles = listOf(movie.filePath)))
            smb.reset(source.id)
            assertTrue(database.movies().get(movie.id)?.isMissing == true)
            assertFalse(source.copy(ignoredFiles = listOf(movie.filePath)).includesFile(movie.filePath))
            assertTrue(runCatching { smb.open(config.copy(ignoredFiles = listOf(movie.filePath)), movie.filePath) }.isFailure)

            smb.open(config, photo.filePath).use { opened ->
                opened.stream(0).use { stream ->
                    assertTrue(stream.read() >= 0)
                    account.disconnect()
                    assertTrue("Disconnect also invalidates bytes already buffered by the handle", runCatching { stream.read() }.isFailure)
                }
            }
            assertNull(store.load(sourceId))
        } finally {
            media.disconnect(sourceId, CLIENT_ID)
            photos.clearMemory()
            context.deleteSharedPreferences(profilePreferences)
            database.close()
        }
    }

    private suspend fun verifyPlayback(factory: DataSource.Factory, uri: android.net.Uri) {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            var engine: ExoPlayer? = null
            var view: PlayerView? = null
            val rendered = AtomicLong(-1)
            try {
                scenario.onActivity { activity ->
                    val exo = ExoPlayer.Builder(activity, DefaultRenderersFactory(activity).setEnableDecoderFallback(true))
                        .setMediaSourceFactory(DefaultMediaSourceFactory(factory))
                        .build()
                    engine = exo
                    exo.setVideoFrameMetadataListener { timeUs, _, _, _ -> rendered.set(timeUs) }
                    view = PlayerView(activity).apply { useController = false; player = exo }
                    activity.setContentView(view)
                    exo.setMediaItem(MediaItem.fromUri(uri))
                    exo.prepare()
                    exo.play()
                }
                val exo = checkNotNull(engine)
                awaitFrames(exo, rendered, 500)
                withContext(Dispatchers.Main) {
                    assertTrue(exo.isCurrentMediaItemSeekable)
                    exo.seekTo(8_000)
                }
                awaitFrames(exo, rendered, 8_500)
            } finally {
                withContext(NonCancellable + Dispatchers.Main) { view?.player = null; engine?.release() }
            }
        }
    }

    private suspend fun awaitFrames(player: ExoPlayer, rendered: AtomicLong, position: Long) = withTimeout(40_000) {
        while (!withContext(Dispatchers.Main) {
            player.playerError?.let { throw it }
            player.playbackState == Player.STATE_READY && player.isPlaying && rendered.get() >= position * 1_000
        }) delay(50)
    }

    private class MemoryAccountStore : OneDriveAccountStore {
        private var account: SavedOneDriveAccount? = null
        override fun load(source: UUID): SavedOneDriveAccount? = account
        override fun save(source: UUID, account: SavedOneDriveAccount) { this.account = account }
        override fun remove(source: UUID) { account = null }
    }

    private class GraphFixture {
        private val assets = InstrumentationRegistry.getInstrumentation().context.assets
        val video = assets.open("playback.mp4").use { it.readBytes() }
        private val photo = assets.open("Photos/01.jpg").use { it.readBytes() }
        val captions = "1\n00:00:00,500 --> 00:00:05,000\nOneDrive fixture caption.\n".toByteArray()
        private val script = "const fixture = true;".toByteArray()
        val downloads = AtomicInteger()
        val lastRangeOffset = AtomicLong()
        @Volatile var rejectFirstAccess = false
        @Volatile private var refreshed = false

        val http = OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request()
            when (request.url.host) {
                "login.microsoftonline.com" -> token(request)
                "graph.microsoft.com" -> graph(request)
                "download.fixture.example" -> download(request)
                else -> error("Unexpected fixture host.")
            }
        }.build()

        private fun token(request: Request): Response {
            assertNull(request.header("Authorization"))
            val form = request.body as FormBody
            val values = (0 until form.size).associate { form.name(it) to form.value(it) }
            assertEquals(CLIENT_ID, values["client_id"])
            return if (request.url.pathSegments.last() == "devicecode") {
                assertTrue(values.getValue("scope").contains("offline_access"))
                response(request, """{"user_code":"FIXTURE","verification_uri":"https://microsoft.com/devicelogin","device_code":"device","expires_in":80,"interval":1}""")
            } else if (values["grant_type"] == "refresh_token") {
                assertTrue(values["refresh_token"] in setOf("first", "renewed"))
                refreshed = true
                response(request, """{"access_token":"renewed-access","refresh_token":"renewed","expires_in":3600}""")
            } else {
                assertEquals("device", values["device_code"])
                response(request, """{"access_token":"first-access","refresh_token":"first","expires_in":3600}""")
            }
        }

        private fun graph(request: Request): Response {
            assertEquals(if (refreshed) "Bearer renewed-access" else "Bearer first-access", request.header("Authorization"))
            if (request.url.encodedPath == "/v1.0/me/drive/items/fixture-root/children" && rejectFirstAccess) {
                rejectFirstAccess = false
                return response(request, """{"error":{"code":"InvalidAuthenticationToken"}}""", 401)
            }
            return when (request.url.encodedPath) {
                "/v1.0/me/drive" -> response(request, """{"id":"fixture-drive"}""")
                "/v1.0/me/drive/root/children" -> page(request, folder("fixture-root", "Fixture media"))
                "/v1.0/me/drive/items/fixture-root/children" -> page(request,
                    folder("public-folder", "Media"), folder("private-folder", "Hidden"),
                    """{"id":"remote","name":"Shared shortcut","folder":{},"remoteItem":{"id":"elsewhere"}}""")
                "/v1.0/me/drive/items/public-folder/children" -> page(request,
                    file("video", "Film.mp4", video.size), file("photo", "Cover.jpg", photo.size),
                    file("subtitle", "Film.en.srt", captions.size), file("script", "code.ts", script.size))
                "/v1.0/me/drive/items/private-folder/children" -> page(request, file("private", "Private.mp4", video.size))
                "/v1.0/me/drive/items/fixture-root:/Media/Film.mp4" -> signed(request, "video", "Film.mp4")
                "/v1.0/me/drive/items/fixture-root:/Media/Cover.jpg" -> signed(request, "photo", "Cover.jpg")
                "/v1.0/me/drive/items/fixture-root:/Media/Film.en.srt" -> signed(request, "subtitle", "Film.en.srt")
                "/v1.0/me/drive/items/fixture-root:/Media/code.ts" -> signed(request, "script", "code.ts")
                else -> error("Read escaped its fixture folder or skipped Graph scope validation.")
            }
        }

        private fun download(request: Request): Response {
            assertNull(request.header("Authorization"))
            assertEquals("identity", request.header("Accept-Encoding"))
            val range = checkNotNull(request.header("Range")).removePrefix("bytes=").split('-').map(String::toInt)
            val bytes = when (request.url.pathSegments.single()) {
                "video" -> video
                "photo" -> photo
                "subtitle" -> captions
                "script" -> script
                else -> error("Unexpected CDN path.")
            }
            val (start, end) = range
            assertTrue(start >= 0 && end >= start && end < bytes.size)
            downloads.incrementAndGet()
            lastRangeOffset.set(start.toLong())
            return response(request, "", 206).newBuilder()
                .header("Content-Range", "bytes $start-$end/${bytes.size}")
                .body(bytes.copyOfRange(start, end + 1).toResponseBody()).build()
        }

        private fun page(request: Request, vararg entries: String) = response(request, """{"value":[${entries.joinToString(",")}]}""")
        private fun folder(id: String, name: String) = """{"id":"$id","name":"$name","folder":{}}"""
        private fun file(id: String, name: String, size: Int) = """{"id":"$id","name":"$name","file":{},"size":$size}"""
        private fun signed(request: Request, id: String, name: String): Response =
            response(request, """{"id":"$id","name":"$name","@microsoft.graph.downloadUrl":"https://download.fixture.example/$id?sig=fixture"}""")
    }

    private companion object {
        const val CLIENT_ID = "12345678-abcd-1234-1234-123456789abc"

        fun response(request: Request, body: String, code: Int = 200) =
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(code).message("Fixture")
                .body(body.toResponseBody()).build()
    }
}
