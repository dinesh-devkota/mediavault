package com.dineshdevkota.cinevault.metadata

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.dineshdevkota.cinevault.data.CineVaultDatabase
import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.data.SourceEntity
import com.dineshdevkota.cinevault.data.saveSourceWithExclusions
import com.dineshdevkota.cinevault.library.LibraryEditor
import com.dineshdevkota.cinevault.playback.PlaybackProgressWriter
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class MetadataMutationTest {
    private fun library(database: CineVaultDatabase) = com.dineshdevkota.cinevault.family.FamilyLibrary(database,
        com.dineshdevkota.cinevault.family.FamilyStore(ApplicationProvider.getApplicationContext(), com.dineshdevkota.cinevault.data.SecretBox(), "isolated-editor-${java.util.UUID.randomUUID()}"))
    private lateinit var database: CineVaultDatabase

    @Before
    fun setUp() {
        database = Room.inMemoryDatabaseBuilder(
            ApplicationProvider.getApplicationContext(), CineVaultDatabase::class.java,
        ).build()
    }

    @After
    fun tearDown() = database.close()

    private suspend fun movie(): MovieEntity {
        val source = SourceEntity(name = "Fixture", host = "localhost", share = "movies")
        database.sources().upsert(source)
        return MovieEntity(
            sourceId = source.id, filePath = "Original (2000).mp4", fileName = "Original (2000).mp4",
            fileSize = 1, parsedTitle = "Original", parsedYear = 2000, title = "Original", year = 2000,
            tmdbId = 1,
        ).also { database.movies().insert(it) }
    }

    @Test fun certificationBackfillKeepsExistingMetadataAndResetInvalidatesIt() = runBlocking {
        val original = movie().copy(title = "Chosen title", overview = "Keep these details", metadataFetched = true)
        database.movies().update(original)
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("fixture")
                .body("""{"id":1,"title":"Different title","overview":"Replace details","release_dates":{"results":[{"iso_3166_1":"US","release_dates":[{"certification":"PG"}]}]}}""".toResponseBody("application/json".toMediaType())).build()
        }.build()
        MetadataService(database, TmdbClient(client) { "fixture" }).fetchMissing()
        val updated = database.movies().get(original.id)!!
        assertEquals(original.title, updated.title)
        assertEquals(original.overview, updated.overview)
        assertEquals("PG", updated.ageCertification)
        assertTrue(updated.certificationFetched)
        MetadataService(database, TmdbClient(client) { "" }).resetToFile(original.id)
        assertNull(database.movies().get(original.id)!!.ageCertification)
        assertFalse(database.movies().get(original.id)!!.certificationFetched)
    }

    @Test fun lateManualMetadataReplyCannotCommitAfterAuthorizationRevoked() = runBlocking {
        val original = movie().copy(ageCertification = "R", certificationFetched = true)
        database.movies().update(original)
        val replies = Replies()
        val service = MetadataService(database, TmdbClient(replies.client) { "fixture" })
        val authorized = java.util.concurrent.atomic.AtomicBoolean(true)
        val request = async(Dispatchers.IO) { runCatching { service.apply(2, original.id, force = true) { check(authorized.get()) } } }
        replies.started.await()
        authorized.set(false); replies.release.countDown()
        assertTrue(request.await().isFailure)
        assertEquals(original, database.movies().get(original.id))
    }

    @Test fun absentCertificationResponseRemainsUnknownAndRetryable() = runBlocking {
        val original = movie().copy(ageCertification = "G", certificationFetched = true)
        database.movies().update(original)
        val replies = Replies("""{"id":2,"title":"Unknown classification"}""").apply { release.countDown() }
        MetadataService(database, TmdbClient(replies.client) { "fixture" }).apply(2, original.id, force = true)
        val current = database.movies().get(original.id)!!
        assertNull(current.ageCertification)
        assertFalse(current.certificationFetched)
    }

    /** Holds the automatic reply while a manual operation is queued. No network is used. */
    private class Replies(private val responseBody: String? = null) {
        val started = CompletableDeferred<Unit>()
        val release = CountDownLatch(1)
        val requests = CopyOnWriteArrayList<Int>()
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            val id = chain.request().url.pathSegments.last().toIntOrNull() ?: 0
            requests += id
            if (requests.size == 1) {
                started.complete(Unit)
                check(release.await(10, TimeUnit.SECONDS)) { "Timed out releasing metadata response" }
            }
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("fixture")
                .body((responseBody ?: """{"id":$id,"title":"Match $id","overview":"Details $id","release_dates":{"results":[]}}""").toResponseBody("application/json".toMediaType()))
                .build()
        }.build()
    }

    @Test
    fun manualMatchWinsOverAnInFlightAutomaticReply() = runBlocking {
        withTimeout(15_000) {
            val movie = movie()
            val replies = Replies()
            val service = MetadataService(database, TmdbClient(replies.client) { "key" })
            val editor = LibraryEditor(database, service, PlaybackProgressWriter(this), library(database))
            val automatic = async(Dispatchers.IO) { service.match(movie) }
            replies.started.await()
            val manual = async(start = CoroutineStart.UNDISPATCHED) { editor.fixMatch(movie.id, 2) }
            try {
                replies.release.countDown()
                automatic.await()
                manual.await()
                val saved = database.movies().get(movie.id)!!
                assertEquals(2, saved.tmdbId)
                assertEquals("Match 2", saved.title)
                assertEquals("Details 2", saved.overview)
                assertTrue(saved.isLocked)
                assertTrue(saved.metadataFetched)
            } finally {
                replies.release.countDown()
            }
        }
    }

    @Test
    fun resetWaitsForAnInFlightReplyThenClearsItsMetadata() = runBlocking {
        withTimeout(15_000) {
            val movie = movie()
            val replies = Replies()
            var key = "key"
            val service = MetadataService(database, TmdbClient(replies.client) { key })
            val automatic = async(Dispatchers.IO) { service.match(movie) }
            replies.started.await()
            key = "" // Reset with no replacement lookup makes the stored state unambiguous.
            val reset = async(start = CoroutineStart.UNDISPATCHED) { service.resetToFile(movie.id) }
            try {
                replies.release.countDown()
                automatic.await()
                reset.await()
                val saved = database.movies().get(movie.id)!!
                assertEquals("Original", saved.title)
                assertNull(saved.tmdbId)
                assertNull(saved.overview)
                assertFalse(saved.metadataFetched)
                assertFalse(saved.isLocked)
            } finally {
                replies.release.countDown()
            }
        }
    }

    @Test
    fun queuedAutomaticMatchReReadsMovieAfterManualMatch() = runBlocking {
        withTimeout(15_000) {
            val movie = movie()
            val replies = Replies()
            val service = MetadataService(database, TmdbClient(replies.client) { "key" })
            val manual = async(Dispatchers.IO) { service.apply(2, movie.id, force = true) }
            replies.started.await()
            val staleAutomatic = async(start = CoroutineStart.UNDISPATCHED) { service.match(movie) }
            try {
                replies.release.countDown()
                manual.await()
                staleAutomatic.await()
                assertEquals(listOf(2), replies.requests)
                assertEquals(2, database.movies().get(movie.id)!!.tmdbId)
            } finally {
                replies.release.countDown()
            }
        }
    }

    @Test
    fun ignoredMovieRejectsAnInFlightDetailsResponseIncludingForcedTitleChanges() = runBlocking {
        withTimeout(15_000) {
            val movie = movie()
            val replies = Replies()
            val service = MetadataService(database, TmdbClient(replies.client) { "fixture-only" })
            val request = async(Dispatchers.IO) { service.apply(2, movie.id, force = true) }
            try {
                replies.started.await()
                val source = database.sources().get(movie.sourceId)!!
                database.saveSourceWithExclusions(source.copy(ignoredFiles = listOf(movie.filePath)))
                replies.release.countDown()
                request.await()
                assertEquals(movie.copy(isMissing = true), database.movies().get(movie.id))
            } finally { replies.release.countDown() }
        }
    }

    @Test
    fun ignoredMovieIsNotMarkedFetchedByAnInFlightEmptySearch() = runBlocking {
        withTimeout(15_000) {
            val movie = movie().copy(tmdbId = null, parsedYear = null, year = null)
            database.movies().update(movie)
            val replies = Replies("""{"results":[]}""")
            val service = MetadataService(database, TmdbClient(replies.client) { "fixture-only" })
            val request = async(Dispatchers.IO) { service.match(movie) }
            try {
                replies.started.await()
                val source = database.sources().get(movie.sourceId)!!
                database.saveSourceWithExclusions(source.copy(ignoredFiles = listOf(movie.filePath)))
                replies.release.countDown()
                request.await()
                assertEquals(movie.copy(isMissing = true), database.movies().get(movie.id))
            } finally { replies.release.countDown() }
        }
    }
}
