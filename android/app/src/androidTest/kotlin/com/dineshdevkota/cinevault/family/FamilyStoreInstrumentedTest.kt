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
        store = FamilyStore(context, SecretBox(), name)
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
        val reloaded = FamilyStore(context, SecretBox(), name)
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
        val reloaded = FamilyStore(context, SecretBox(), name)
        assertTrue(reloaded.unlock(HouseholdProfile.ADMIN, "123456")!!.contains("Too many"))
        assertFalse(reloaded.current.unlocked)
    }
    @Test fun unreadableConfiguredControlsFailClosed() = runBlocking {
        admin()
        context.getSharedPreferences(name, Context.MODE_PRIVATE).edit().putString("record", "damaged").commit()
        val damaged = FamilyStore(context, SecretBox(), name)
        assertTrue(damaged.current.damaged)
        assertFalse(damaged.current.admin)
        assertNotNull(damaged.unlock(HouseholdProfile.ADMIN, "123456"))
        assertFalse(damaged.current.unlocked)
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
}
