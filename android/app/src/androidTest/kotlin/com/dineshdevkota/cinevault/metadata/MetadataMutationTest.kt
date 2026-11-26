package com.dineshdevkota.cinevault.metadata

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.dineshdevkota.cinevault.data.CineVaultDatabase
import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.data.SourceEntity
import com.dineshdevkota.cinevault.data.saveSourceWithExclusions
import com.dineshdevkota.cinevault.library.LibraryEditor
import com.dineshdevkota.cinevault.family.FamilyPolicy
import com.dineshdevkota.cinevault.family.FolderAccess
import com.dineshdevkota.cinevault.family.HouseholdProfile
import com.dineshdevkota.cinevault.playback.PlaybackProgressWriter
import com.dineshdevkota.cinevault.plex.PLEX
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
        com.dineshdevkota.cinevault.family.FamilyStore(ApplicationProvider.getApplicationContext(), com.dineshdevkota.cinevault.data.SecretBox(androidx.test.core.app.ApplicationProvider.getApplicationContext()), "isolated-editor-${java.util.UUID.randomUUID()}"))
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

    private suspend fun plexMovie(episode: Boolean = false): MovieEntity {
        val source = SourceEntity(name = "Plex fixture", host = "https://fixture.invalid", share = "1", sourceType = PLEX)
        database.sources().upsert(source)
        val path = if (episode) "plex/shows/201/203.mp4" else "plex/movies/101.mp4"
        return MovieEntity(
            sourceId = source.id, filePath = path, fileName = "Server title.mp4", fileSize = 1,
            parsedTitle = "Server title", parsedYear = 2000, title = "Server title", year = 2000,
            tmdbId = if (episode) null else 1,
            seriesTitle = if (episode) "Server show" else null, seriesTmdbId = if (episode) 1 else null,
            seasonNumber = if (episode) 1 else null, episodeNumber = if (episode) 2 else null,
            ageCertification = if (episode) "TV-MA" else "G", certificationFetched = true, metadataFetched = true,
        ).also { database.movies().insert(it) }
    }

    private fun restrictedProfile(movie: MovieEntity) = HouseholdProfile(
        "viewer", "Viewer", folders = listOf(FolderAccess(movie.sourceId, "plex", caseSensitive = true)),
        movieLimit = "G", tvLimit = "TV-G",
    )

    @Test fun plexManualMovieMatchKeepsTheRatingUpdatedWhileItsReplyWasPending() = runBlocking {
        val original = plexMovie()
        val profile = restrictedProfile(original)
        assertTrue(FamilyPolicy.allows(profile, original))
        val replies = Replies("""{"id":2,"title":"Corrected title","release_dates":{"results":[{"iso_3166_1":"US","release_dates":[{"certification":"G"}]}]}}""")
        val service = MetadataService(database, TmdbClient(replies.client) { "fixture" })
        val editor = LibraryEditor(database, service, PlaybackProgressWriter(this), library(database))
        val request = async(Dispatchers.IO) { editor.fixMatch(original.id, 2) }
        try {
            replies.started.await()
            // A Plex rescan can finish while the manual TMDB request is awaiting its reply.
            database.movies().update(original.copy(ageCertification = "R"))
            replies.release.countDown()
            request.await()
            val updated = checkNotNull(database.movies().get(original.id))
            assertEquals("Corrected title", updated.title)
            assertEquals("R", updated.ageCertification)
            assertTrue(updated.certificationFetched)
            assertFalse(FamilyPolicy.allows(profile, updated))
        } finally { replies.release.countDown() }
    }

    @Test fun plexManualTvMatchPreservesRestrictedAndUnknownServerRatings() = runBlocking {
        val original = plexMovie(episode = true)
        val requests = CopyOnWriteArrayList<String>()
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            requests += chain.request().url.encodedPath
            val body = if (chain.request().url.encodedPath.contains("/season/")) {
                """{"id":1,"season_number":1,"episodes":[{"id":3,"season_number":1,"episode_number":2,"name":"Corrected episode"}]}"""
            } else {
                """{"id":2,"name":"Corrected show","content_ratings":{"results":[{"iso_3166_1":"US","rating":"TV-G"}]}}"""
            }
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("fixture")
                .body(body.toResponseBody("application/json".toMediaType())).build()
        }.build()
        val service = MetadataService(database, TmdbClient(client) { "fixture" })
        val editor = LibraryEditor(database, service, PlaybackProgressWriter(this), library(database))
        for (serverRating in listOf("TV-MA", null)) {
            database.movies().update(original.copy(ageCertification = serverRating))
            editor.fixTVMatch(original.id, 2)
            val updated = checkNotNull(database.movies().get(original.id))
            assertEquals("Corrected episode", updated.title)
            assertEquals("Corrected show", updated.seriesTitle)
            assertEquals(original.seasonNumber, updated.seasonNumber)
            assertEquals(original.episodeNumber, updated.episodeNumber)
            assertEquals(serverRating, updated.ageCertification)
            assertTrue(updated.certificationFetched)
            assertFalse(FamilyPolicy.allows(restrictedProfile(original), updated))
        }
        assertTrue(requests.isNotEmpty())
    }

    @Test fun plexResetAndAutomaticMetadataCannotDiscardServerIdentityOrClassification() = runBlocking {
        val original = plexMovie(episode = true)
        var requests = 0
        val client = OkHttpClient.Builder().addInterceptor {
            requests++
            error("Automatic metadata must not query TMDB for a Plex catalog item.")
        }.build()
        val service = MetadataService(database, TmdbClient(client) { "fixture" })
        val editor = LibraryEditor(database, service, PlaybackProgressWriter(this), library(database))
        assertTrue(runCatching { editor.resetToFile(original.id) }.exceptionOrNull() is MetadataException)
        assertEquals(original, database.movies().get(original.id))
        // Explicit calls must obey the provider boundary, including old incomplete records.
        for (pending in listOf(original.copy(certificationFetched = false), original.copy(metadataFetched = false))) {
            database.movies().update(pending)
            service.match(pending)
            assertEquals(pending, database.movies().get(original.id))
        }
        database.movies().update(original)
        service.refreshAll()
        assertEquals(original, database.movies().get(original.id))
        assertEquals(0, requests)
        assertFalse(FamilyPolicy.allows(restrictedProfile(original), checkNotNull(database.movies().get(original.id))))
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
