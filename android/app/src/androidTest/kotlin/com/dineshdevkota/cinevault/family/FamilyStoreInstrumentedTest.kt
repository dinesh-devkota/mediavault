package com.dineshdevkota.cinevault.family

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.dineshdevkota.cinevault.data.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

/** Separate encrypted preferences and in-memory rows; never changes the installed household. */
@RunWith(AndroidJUnit4::class)
class FamilyStoreInstrumentedTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private lateinit var name: String
    private lateinit var store: FamilyStore
    private lateinit var db: CineVaultDatabase
    private lateinit var library: FamilyLibrary
    @Before fun prepare() {
        name = "family-fixture-${UUID.randomUUID()}"
        store = FamilyStore(context, SecretBox(androidx.test.core.app.ApplicationProvider.getApplicationContext()), name)
        db = Room.inMemoryDatabaseBuilder(context, CineVaultDatabase::class.java).build()
        library = FamilyLibrary(db, store)
    }
    @After fun clean() { db.close(); context.getSharedPreferences(name, Context.MODE_PRIVATE).edit().clear().commit() }
    private suspend fun admin() {
        store.setup("123456", "123456")
        assertFalse(store.current.unlocked)
        assertNull(store.unlock(HouseholdProfile.ADMIN, "123456"))
    }
    private suspend fun addViewer(pin: String? = null): HouseholdProfile {
        val viewer = HouseholdProfile("viewer", "Viewer", folders = listOf(FolderAccess("nas", "Kids")), movieLimit = "PG")
        store.saveProfile(viewer, pin)
        return store.profiles.first { it.id == viewer.id }
    }
    private suspend fun movie(id: String = "movie", path: String = "Kids/Film.mp4", rating: String? = "PG"): MovieEntity {
        db.sources().upsert(SourceEntity(id = "nas", name = "Fixture", host = "127.0.0.1", port = 1, share = "fixture"))
        return MovieEntity(id = id, sourceId = "nas", filePath = path, fileName = path.substringAfterLast('/'), fileSize = 10,
            parsedTitle = id, parsedYear = null, title = id, year = null, ageCertification = rating)
            .also { db.movies().insert(it) }
    }

    @Test fun disabledControlsPreserveExistingHistoryAndConfiguredRelaunchLocks() = runBlocking {
        movie(); db.movies().markFinished("movie", 90_000, 1)
        assertTrue(library.get("movie")!!.isWatched)
        admin()
        assertTrue(library.get("movie")!!.isWatched)
        val reloaded = FamilyStore(context, SecretBox(androidx.test.core.app.ApplicationProvider.getApplicationContext()), name)
        assertTrue(reloaded.current.enabled)
        assertFalse(reloaded.current.unlocked)
        assertNull(FamilyLibrary(db, reloaded).get("movie"))
        val sealed = context.getSharedPreferences(name, Context.MODE_PRIVATE).getString("record", "")!!
        assertFalse(sealed.contains("123456"))
        assertFalse(sealed.contains("Admin"))
    }
    @Test fun viewersCannotChangePermissionsAndEachProtectedProfileNeedsItsPIN() = runBlocking {
        admin(); addViewer("654321"); store.lock()
        assertNotNull(store.unlock("viewer", "123456"))
        assertNull(store.unlock("viewer", "654321"))
        assertFalse(store.current.admin)
        try { store.saveProfile(HouseholdProfile("attack", "Attack"), null); fail("Viewer changed permissions") }
        catch (_: IllegalStateException) { }
        assertNotNull(store.unlock(HouseholdProfile.ADMIN, "654321"))
        assertFalse(store.current.admin)
    }
    @Test fun retryCounterSurvivesRestartAndUnprotectedViewerCannotResetAdminAttempts() = runBlocking {
        admin(); addViewer(); store.lock()
        repeat(4) { assertNotNull(store.unlock(HouseholdProfile.ADMIN, "999999")) }
        assertNull(store.unlock("viewer", ""))
        assertTrue(store.unlock(HouseholdProfile.ADMIN, "999999")!!.contains("Too many"))
        val reloaded = FamilyStore(context, SecretBox(androidx.test.core.app.ApplicationProvider.getApplicationContext()), name)
        assertTrue(reloaded.unlock(HouseholdProfile.ADMIN, "123456")!!.contains("Too many"))
        assertFalse(reloaded.current.unlocked)
    }
    @Test fun unreadableConfiguredControlsFailClosed() = runBlocking {
        admin()
        context.getSharedPreferences(name, Context.MODE_PRIVATE).edit().putString("record", "damaged").commit()
        val damaged = FamilyStore(context, SecretBox(androidx.test.core.app.ApplicationProvider.getApplicationContext()), name)
        assertTrue(damaged.current.damaged)
        assertFalse(damaged.current.admin)
        assertNotNull(damaged.unlock(HouseholdProfile.ADMIN, "123456"))
        assertFalse(damaged.current.unlocked)
    }

    @Test fun onlyAdminChangingAPINClearsThatProfilesOldCooldown() = runBlocking {
        admin(); val viewer = addViewer("654321"); store.lock()
        repeat(5) { store.unlock(viewer.id, "999999") }
        store.unlock(HouseholdProfile.ADMIN, "123456")
        store.saveProfile(viewer.copy(name = "Renamed viewer"), null)
        assertTrue(store.unlock(viewer.id, "654321")!!.contains("Too many"))
        store.saveProfile(viewer.copy(name = "Renamed viewer"), null, removePin = true)
        assertNull(store.unlock(viewer.id, ""))
        assertEquals(viewer.id, store.current.historyId)
    }
    @Test fun watchResumeAndWatchlistArePrivateAndOldSessionCannotWriteAfterSwitch() = runBlocking {
        movie(); db.movies().markFinished("movie", 90_000, 1); db.movies().setWatchlisted("movie", true)
        admin(); addViewer(); val owner = store.current
        store.lock(); store.unlock("viewer", "")
        assertFalse(library.get("movie")!!.isWatched)
        assertFalse(library.get("movie")!!.isWatchlisted)
        library.saveProgress("movie", 40_000, 90_000, 20, store.current)
        library.setWatchlisted("movie", true)
        assertEquals(40_000L, library.get("movie")!!.playbackPositionMs)
        library.saveProgress("movie", 9_000, 90_000, 30, owner)
        assertTrue(db.movies().get("movie")!!.isWatched)
        assertEquals(0L, db.movies().get("movie")!!.playbackPositionMs)
        store.lock(); store.unlock(HouseholdProfile.ADMIN, "123456")
        assertTrue(library.get("movie")!!.isWatched)
    }

    @Test fun authorizedFinalPlaybackCheckpointStaysWithOriginalProfileAfterBackgroundLock() = runBlocking {
        val movie = movie(); admin(); addViewer()
        val checkpoint = requireNotNull(library.playbackCheckpoint(movie, store.current, 31_000, 90_000, 1, finished = false))
        val old = store.current
        store.lock(); store.unlock("viewer", "")
        checkpoint()
        assertEquals(31_000L, db.movies().get(movie.id)!!.playbackPositionMs)
        assertEquals(0L, library.get(movie.id)!!.playbackPositionMs)
        assertNull(library.playbackCheckpoint(movie, old, 50_000, 90_000, 2, finished = false))
    }
    @Test fun displayDirectReadsAndBulkActionsUseTheSamePolicy() = runBlocking {
        movie(); movie("private", "Private/Secret.mp4", "R"); movie("unrated", "Kids/Unrated.mp4", null)
        admin(); addViewer(); store.lock(); store.unlock("viewer", "")
        assertEquals(listOf("movie"), library.observeAll().first().map { it.id })
        assertNull(library.get("private")); assertNull(library.get("unrated"))
        assertEquals(1, library.setWatched(listOf("movie", "private", "unrated"), true))
        assertNull(db.profileHistory().get("viewer", "private"))
        store.lock()
        assertTrue(library.observeAll().first().isEmpty())
    }
    @Test fun backgroundDuringPinVerificationCannotReopenAdmin() = runBlocking {
        admin(); store.lock()
        val unlock = async(Dispatchers.Default, start = CoroutineStart.UNDISPATCHED) { store.unlock(HouseholdProfile.ADMIN, "123456") }
        delay(10)
        store.lock()
        unlock.await()
        assertFalse(store.current.unlocked)
    }

    @Test fun queuedAuthenticationCannotRunInBackgroundOrReuseAnOldPromptAfterReturn() = runBlocking {
        admin(); store.lock()
        val prompt = store.authenticationEpoch
        store.onBackground()
        assertNotNull(async(Dispatchers.Default) { store.unlock(HouseholdProfile.ADMIN, "123456", prompt) }.await())
        assertFalse(store.current.unlocked)
        store.onForeground()
        assertNotNull(store.unlock(HouseholdProfile.ADMIN, "123456", prompt))
        assertFalse(store.current.unlocked)
        assertNull(store.unlock(HouseholdProfile.ADMIN, "123456"))
    }

    @Test fun profileNamesAndPermissionsAreValidatedBeforePersistence() = runBlocking {
        admin(); addViewer()
        for (invalid in listOf(HouseholdProfile("other", " viewer "), HouseholdProfile("other", "ADMIN"),
            HouseholdProfile("other", "Other", movieLimit = "8.5"),
            HouseholdProfile("other", "Other", folders = listOf(FolderAccess("nas", "Kids/../Private"))))) {
            try { store.saveProfile(invalid, null); fail("Invalid profile was saved") }
            catch (_: IllegalArgumentException) { }
        }
        assertEquals(2, store.profiles.size)
        assertFalse(FamilyStore(context, SecretBox(androidx.test.core.app.ApplicationProvider.getApplicationContext()), name).current.damaged)
    }

    @Test fun turningProfilesOffIsAuthenticatedAndRestoringUsesTheExistingPINAndHistory() = runBlocking {
        movie(); admin(); addViewer(); store.lock(); store.unlock("viewer", "")
        library.setWatchlisted("movie", true)
        try { store.turnOff(); fail("Viewer disabled household protection") } catch (_: IllegalStateException) { }
        store.unlock(HouseholdProfile.ADMIN, "123456"); store.turnOff()
        assertFalse(store.current.enabled)
        assertNotNull(library.get("movie"))
        try { store.setup("999999", "999999"); fail("Disabled household replaced its Admin PIN") } catch (_: IllegalStateException) { }
        try { store.saveProfile(HouseholdProfile("attack", "Attack"), null); fail("Disabled household changed protected profiles") } catch (_: IllegalStateException) { }
        val restarted = FamilyStore(context, SecretBox(androidx.test.core.app.ApplicationProvider.getApplicationContext()), name)
        assertFalse(restarted.current.enabled)
        assertNotNull(restarted.unlock("viewer", ""))
        assertNotNull(restarted.unlock(HouseholdProfile.ADMIN, "999999"))
        assertNull(restarted.unlock(HouseholdProfile.ADMIN, "123456"))
        restarted.lock(); restarted.unlock("viewer", "")
        assertTrue(FamilyLibrary(db, restarted).get("movie")!!.isWatchlisted)
    }

    @Test fun libraryFiltersRemainPrivateAndAdminKeepsExistingPreferences() {
        val prefix = "preferences-$name-"
        val isolated = object : android.content.ContextWrapper(context) {
            override fun getSharedPreferences(preferenceName: String, mode: Int) = context.getSharedPreferences(prefix + preferenceName, mode)
        }
        var id = "admin"
        val settings = Settings(isolated, SecretBox(androidx.test.core.app.ApplicationProvider.getApplicationContext())) { id }
        try {
            val owner = com.dineshdevkota.cinevault.core.LibraryFacets(genres = setOf("Private genre"), sourceIds = setOf("private"))
            settings.libraryFacets = owner
            settings.librarySort = com.dineshdevkota.cinevault.core.LibrarySort.YEAR
            id = "viewer"
            assertEquals(com.dineshdevkota.cinevault.core.LibraryFacets(), settings.libraryFacets)
            assertEquals(com.dineshdevkota.cinevault.core.LibrarySort.TITLE, settings.librarySort)
            settings.libraryFacets = com.dineshdevkota.cinevault.core.LibraryFacets(genres = setOf("Family"))
            id = "admin"
            assertEquals(owner, settings.libraryFacets)
            assertEquals(com.dineshdevkota.cinevault.core.LibrarySort.YEAR, settings.librarySort)
        } finally {
            context.deleteSharedPreferences(prefix + "settings")
            context.deleteSharedPreferences(prefix + "library-profile-viewer")
        }
    }

    @Test fun photoCacheAndDelayedBytesCannotCrossALock() = runBlocking {
        admin()
        val photo = movie("photo", "Kids/Photo.png", null)
        val output = java.io.ByteArrayOutputStream()
        android.graphics.Bitmap.createBitmap(2, 2, android.graphics.Bitmap.Config.ARGB_8888).let {
            it.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, output); it.recycle()
        }
        val bytes = output.toByteArray()
        var reads = 0
        var delayed = false
        val started = java.util.concurrent.CountDownLatch(1)
        val release = java.util.concurrent.CountDownLatch(1)
        val loader = com.dineshdevkota.cinevault.photos.NasPhotoLoader(context, db, SecretBox(androidx.test.core.app.ApplicationProvider.getApplicationContext()), family = store,
            openFile = { _, _ ->
                reads++
                object : com.dineshdevkota.cinevault.smb.RemoteHandle {
                    override val length = bytes.size.toLong()
                    override fun close() = Unit
                    override fun stream(position: Long): java.io.InputStream = object : java.io.ByteArrayInputStream(bytes) {
                        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                            if (delayed) { started.countDown(); check(release.await(10, java.util.concurrent.TimeUnit.SECONDS)) }
                            return super.read(buffer, offset, length)
                        }
                    }
                }
            })
        assertEquals(2, loader.load(photo.id).width)
        store.lock()
        assertTrue(runCatching { loader.load(photo.id) }.isFailure)
        assertEquals(1, reads)
        store.unlock(HouseholdProfile.ADMIN, "123456")
        loader.clearMemory(); delayed = true
        val pending = async(Dispatchers.IO) { runCatching { loader.load(photo.id) } }
        assertTrue(withContext(Dispatchers.IO) { started.await(10, java.util.concurrent.TimeUnit.SECONDS) })
        store.lock(); release.countDown()
        assertTrue(pending.await().isFailure)
    }
}
