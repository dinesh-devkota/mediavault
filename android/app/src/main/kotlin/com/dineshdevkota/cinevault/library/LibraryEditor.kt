package com.dineshdevkota.cinevault.library

import androidx.room.withTransaction
import com.dineshdevkota.cinevault.core.TitleEdit
import com.dineshdevkota.cinevault.core.TmdbMovieSummary
import com.dineshdevkota.cinevault.core.WatchRules
import com.dineshdevkota.cinevault.data.CineVaultDatabase
import com.dineshdevkota.cinevault.metadata.MetadataService
import com.dineshdevkota.cinevault.playback.PlaybackProgressWriter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Manual library management from the Edit screen: rename, re-match, and resets (tvOS parity).
 * TMDB calls run on [Dispatchers.IO] because reading the sealed API key blocks.
 */
class LibraryEditor(
    private val database: CineVaultDatabase,
    private val metadata: MetadataService,
    private val progressWriter: PlaybackProgressWriter,
    private val library: com.dineshdevkota.cinevault.family.FamilyLibrary,
) {
    private fun adminAuthorization(): () -> Unit {
        library.family.requireAdmin()
        val token = library.family.current
        return { check(library.family.isCurrent(token) && token.admin) { "Your Admin session has locked. Try again after unlocking." } }
    }
    suspend fun rename(movieId: String, edit: TitleEdit.Valid) {
        val authorize = adminAuthorization()
        database.withTransaction { authorize(); database.movies().rename(movieId, edit.title, WatchRules.sortTitle(edit.title), edit.year) }
    }

    suspend fun search(query: String): List<TmdbMovieSummary> = withContext(Dispatchers.IO) {
        library.family.requireAdmin()
        metadata.tmdb.search(query.trim(), null)
    }

    suspend fun searchTV(query: String): List<TmdbMovieSummary> = withContext(Dispatchers.IO) {
        library.family.requireAdmin()
        metadata.tmdb.searchTV(query.trim(), null)
    }

    suspend fun fixTVMatch(movieId: String, seriesId: Int) = withContext(Dispatchers.IO) {
        metadata.applyTV(seriesId, movieId, force = true, authorize = adminAuthorization())
    }

    /** Takes TMDB's title and details for the chosen result and locks them against automatic matching. */
    suspend fun fixMatch(movieId: String, tmdbId: Int) = withContext(Dispatchers.IO) {
        metadata.apply(tmdbId, movieId, force = true, authorize = adminAuthorization())
    }

    suspend fun resetProgress(movieId: String) = setWatched(movieId, false)

    /** Queue behind the player's final save so it cannot undo this later user action. */
    suspend fun setWatched(movieId: String, watched: Boolean) {
        val token = library.family.current
        progressWriter.await { library.setWatched(movieId, watched, token) }
    }

    /** One atomic edit, ordered after player saves and bounded below SQLite's bind limit. */
    suspend fun setWatched(movieIds: Collection<String>, watched: Boolean): Int {
        val token = library.family.current
        return progressWriter.await {
        database.withTransaction {
            val sources = database.sources().all()
            movieIds.distinct().chunked(900).sumOf { chunk ->
                val ids = watchStatusItems(library.forIds(chunk), sources).map { it.id }
                if (ids.isEmpty()) 0 else library.setWatched(ids, watched, token)
            }
        }
        }
    }

    /**
     * Back to what a fresh scan shows, then matched straight away when a TMDB key is set. If matching fails the
     * movie stays reset and is matched again after the next scan; the thrown message says so.
     */
    suspend fun resetToFile(movieId: String) = withContext(Dispatchers.IO) {
        metadata.resetToFile(movieId, authorize = adminAuthorization())
    }
}
