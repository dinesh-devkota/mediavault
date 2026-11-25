package com.dineshdevkota.cinevault.data

import android.content.Context
import androidx.room.Room
import androidx.room.withTransaction
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import com.dineshdevkota.cinevault.library.LibraryEditor
import com.dineshdevkota.cinevault.metadata.MetadataService
import com.dineshdevkota.cinevault.metadata.TmdbClient
import com.dineshdevkota.cinevault.playback.PlaybackProgressWriter
import okhttp3.OkHttpClient
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LibraryDatabaseTest {
    private fun library(database: CineVaultDatabase) = com.dineshdevkota.cinevault.family.FamilyLibrary(database,
        com.dineshdevkota.cinevault.family.FamilyStore(ApplicationProvider.getApplicationContext(), SecretBox(androidx.test.core.app.ApplicationProvider.getApplicationContext()), "isolated-editor-${java.util.UUID.randomUUID()}"))
    private lateinit var db: CineVaultDatabase

    @Before
    fun openDatabase() {
        db = Room.inMemoryDatabaseBuilder(
            ApplicationProvider.getApplicationContext<Context>(), CineVaultDatabase::class.java,
        ).build()
    }

    @After
    fun closeDatabase() = db.close()

    @Test
    fun scanAndMetadataUpdatesPreservePlaybackAndManualTitle() = runBlocking {
        insertMovie()
        db.movies().rename("movie", "My title", "my title", 2001)
        db.movies().saveProgress("movie", 60_000, 120_000, 1)
        db.movies().markMissing("movie")
        db.movies().markPresent("movie", 512)
        db.movies().applyMetadata("movie", 603, "Overview", null, 120, 8.5, "/p.jpg", null, "[\"Drama\"]")
        db.movies().applyMatchedTitle("movie", "Automatic title", "automatic title", 1999, false)
        val movie = requireNotNull(db.movies().get("movie"))
        assertEquals("My title", movie.title)
        assertEquals(2001, movie.year)
        assertEquals(60_000L, movie.playbackPositionMs)
        assertEquals(120_000L, movie.durationMs)
        assertFalse(movie.isMissing)
        assertTrue(movie.metadataFetched)
        assertEquals(listOf("Drama"), movie.genres)
    }

    @Test
    fun deletingSourceCascadesToItsMovies() = runBlocking {
        insertMovie()
        db.sources().delete("source")
        assertNull(db.movies().get("movie"))
    }

    @Test
    fun bulkWatchedChangesMoreThanOneSqlBatchAndRollsBackIfAnyBatchFails() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val writer = PlaybackProgressWriter(scope)
        val editor = LibraryEditor(db, MetadataService(db, TmdbClient(OkHttpClient()) { "" }), writer, library(db))
        try {
            insertMovie()
            val original = requireNotNull(db.movies().get("movie"))
            val ids = (0 until 1_105).map { "batch-$it" }
            db.withTransaction {
                ids.forEach { id -> db.movies().insert(original.copy(id = id, filePath = "$id.mp4",
                    isWatched = true, playbackPositionMs = 50_000, durationMs = 90_000, lastPlayedAt = 123L,
                    isWatchlisted = true)) }
            }
            // Duplicate IDs must count once, and existing watched rows still clear their resume.
            assertEquals(1_105, editor.setWatched(ids + ids.take(10), true))
            val updated = db.movies().forSource("source").filter { it.id in ids }
            assertTrue(updated.all { it.isWatched && it.playbackPositionMs == 0L })
            assertTrue(updated.all { it.lastPlayedAt == 123L && it.durationMs == 90_000L && it.isWatchlisted })
            assertFalse(requireNotNull(db.movies().get("movie")).isWatched)

            db.openHelper.writableDatabase.execSQL("CREATE TEMP TRIGGER reject_second_batch BEFORE UPDATE ON movies " +
                "WHEN NEW.id = 'batch-950' BEGIN SELECT RAISE(ABORT, 'synthetic transaction failure'); END")
            assertTrue(runCatching { editor.setWatched(ids, false) }.isFailure)
            assertTrue(db.movies().forSource("source").filter { it.id in ids }.all { it.isWatched })
            db.openHelper.writableDatabase.execSQL("DROP TRIGGER reject_second_batch")
            assertEquals(1_105, editor.setWatched(ids, false))
            assertTrue(db.movies().forSource("source").filter { it.id in ids }.all { !it.isWatched && it.playbackPositionMs == 0L })
        } finally {
            scope.cancel()
        }
    }

    @Test
    fun bulkWatchedWaitsForPlayerAndRechecksCurrentSourceRules() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val writer = PlaybackProgressWriter(scope)
        val editor = LibraryEditor(db, MetadataService(db, TmdbClient(OkHttpClient()) { "" }), writer, library(db))
        try {
            insertMovie()
            val original = requireNotNull(db.movies().get("movie"))
            db.movies().insert(original.copy(id = "excluded", filePath = "Ignored/Clip.mp4"))
            db.movies().insert(original.copy(id = "audio", filePath = "Music/song.mp3"))
            db.movies().insert(original.copy(id = "photo", filePath = "Photos/image.jpg"))
            db.movies().insert(original.copy(id = "missing", filePath = "Missing.mp4", isMissing = true))
            db.movies().insert(original.copy(id = "concert", filePath = "Music/Concert.mp4"))
            db.movies().insert(original.copy(id = "hidden", filePath = "Hidden.mp4", isHidden = true))
            val playerStarted = CompletableDeferred<Unit>()
            val finishPlayer = CompletableDeferred<Unit>()
            writer.enqueue {
                playerStarted.complete(Unit)
                finishPlayer.await()
                db.movies().saveProgress("movie", 67_000, 90_000, 789L)
            }
            playerStarted.await()
            val update = async { editor.setWatched(listOf("movie", "excluded", "audio", "photo", "missing", "concert", "hidden", "gone"), true) }
            db.sources().upsert(requireNotNull(db.sources().get("source")).copy(ignoredFolders = listOf("Ignored")))
            finishPlayer.complete(Unit)
            assertEquals(3, update.await())
            val movie = requireNotNull(db.movies().get("movie"))
            assertTrue(movie.isWatched)
            assertEquals(0L, movie.playbackPositionMs)
            assertEquals(789L, movie.lastPlayedAt)
            assertTrue(requireNotNull(db.movies().get("concert")).isWatched)
            assertTrue(requireNotNull(db.movies().get("hidden")).isWatched)
            for (id in listOf("excluded", "audio", "photo", "missing")) assertFalse(requireNotNull(db.movies().get(id)).isWatched)
        } finally {
            scope.cancel()
        }
    }

    private suspend fun insertMovie() {
        db.sources().upsert(SourceEntity(id = "source", name = "Test NAS", host = "localhost", share = "fixture"))
        db.movies().insert(
            MovieEntity(
                id = "movie", sourceId = "source", filePath = "Movie.mp4", fileName = "Movie.mp4",
                fileSize = 256, parsedTitle = "Movie", parsedYear = 1999, title = "Movie", year = 1999,
            ),
        )
    }
}
