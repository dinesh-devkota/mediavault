package com.dineshdevkota.cinevault.metadata

import androidx.room.withTransaction
import com.dineshdevkota.cinevault.core.MovieEdits
import com.dineshdevkota.cinevault.core.MediaFile
import com.dineshdevkota.cinevault.core.EpisodeInfo
import com.dineshdevkota.cinevault.core.TitleMatcher
import com.dineshdevkota.cinevault.core.WatchRules
import com.dineshdevkota.cinevault.data.CineVaultDatabase
import com.dineshdevkota.cinevault.data.Converters
import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.jellyfin.JELLYFIN
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.concurrent.atomic.AtomicInteger

class MetadataFetchSummary(val attempted: Int, val failed: Int, val firstError: String?) {
    val failureMessage: String?
        get() = if (failed == 0) null else "Metadata failed for $failed of $attempted movies. ${firstError ?: "Try again."}"
}

/** Matches library movies to TMDB and stores posters and details. Batches run one at a time. */
class MetadataService(private val database: CineVaultDatabase, val tmdb: TmdbClient) {
    private val batchLock = Mutex()
    // Keep automatic replies and explicit edits in order across their network suspensions.
    // A batch must re-read after acquiring this lock: an edit may have finished while it waited.
    private val mutationLock = Mutex()
    private val active = AtomicInteger(0)
    private val running = MutableStateFlow(false)
    private val statusFlow = MutableStateFlow<String?>(null)
    private val converters = Converters()

    val isRunning: StateFlow<Boolean> = running.asStateFlow()
    val status: StateFlow<String?> = statusFlow.asStateFlow()

    fun clearStatus() {
        statusFlow.value = null
    }

    /** Matches movies without metadata (runs after every scan). Null when no TMDB key is set. */
    suspend fun fetchMissing(): MetadataFetchSummary? = runBatch(refreshAll = false)

    /** Re-fetches every movie; existing matches and locked titles are kept. */
    suspend fun refreshAll(): MetadataFetchSummary? = runBatch(refreshAll = true)

    /** Adds franchise membership to older libraries without replacing their titles, artwork or viewing history. */
    suspend fun refreshMovieCollections(authorize: () -> Unit = {}) {
        authorize()
        if (!tmdb.hasKey()) { statusFlow.value = "Local NFO movie series appear after a scan. Add a TMDB key in Settings to find more online."; return }
        active.incrementAndGet(); running.value = true
        try {
            batchLock.withLock {
                val providers = database.sources().all().filter { it.sourceType == JELLYFIN }.map { it.id }.toSet()
                val pending = database.movies().available().filter { it.tmdbId != null && it.episodeInfo == null && !it.isPhoto && it.sourceId !in providers }
                var failed = 0
                for ((index, queued) in pending.withIndex()) {
                    authorize(); statusFlow.value = "Finding movie series ${index + 1} of ${pending.size}…"
                    try {
                        mutationLock.withLock {
                            val current = database.movies().get(queued.id)?.takeUnless { it.isMissing } ?: return@withLock
                            val id = current.tmdbId ?: return@withLock
                            val details = tmdb.details(id)
                            database.withTransaction {
                                authorize()
                                val latest = database.movies().get(current.id) ?: return@withTransaction
                                if (sameMatch(latest, current)) {
                                    val online = latest.copy(franchiseId = details.collection?.id, franchiseName = details.collection?.name?.takeIf { it.isNotBlank() })
                                    database.movies().update(LocalMetadataImporter.reapply(online))
                                }
                            }
                        }
                    } catch (cancelled: CancellationException) { throw cancelled }
                    catch (failure: MetadataException) { if (failure.isAuthFailure) throw failure; failed++ }
                    catch (_: Exception) { failed++ }
                }
                statusFlow.value = if (failed > 0) "Movie series updated; $failed titles could not be checked. Try again when connected."
                    else "Movie series updated. Collections with two or more titles appear here."
            }
        } finally { if (active.decrementAndGet() == 0) running.value = false }
    }

    private suspend fun runBatch(refreshAll: Boolean): MetadataFetchSummary? {
        val hasKey = try {
            tmdb.hasKey()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            statusFlow.value = e.message ?: "Could not read the saved TMDB key. Enter it again in Settings."
            throw e
        }
        if (!hasKey) {
            if (refreshAll) statusFlow.value = "Add a TMDB key first."
            return null
        }
        active.incrementAndGet()
        running.value = true
        try {
            return batchLock.withLock {
                val movies = database.movies()
                if (refreshAll) { movies.clearMetadataFetched(); tmdb.clearTVCache() }
                val providers = database.sources().all().filter { it.sourceType == JELLYFIN }.map { it.id }.toSet()
                val pending = movies.available().filter {
                    it.sourceId !in providers && needsMetadata(it) && !MediaFile.isAudio(it.filePath)
                }
                var failed = 0
                var firstError: String? = null
                for ((index, queued) in pending.withIndex()) {
                    statusFlow.value = "Fetching metadata ${index + 1} of ${pending.size}…"
                    // Re-read so a fix or reset made on the Edit screen during a long batch is not undone.
                    val movie = movies.get(queued.id)?.takeIf { needsMetadata(it) && !it.isMissing } ?: continue
                    try {
                        match(movie)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        failed++
                        if (firstError == null) firstError = TmdbClient.describe(e)
                        // A rejected key fails every remaining request too.
                        if (e is MetadataException && e.isAuthFailure) {
                            failed += pending.size - index - 1
                            break
                        }
                    }
                }
                MetadataFetchSummary(pending.size, failed, firstError).also { summary ->
                    statusFlow.value = summary.failureMessage ?: when {
                        pending.isEmpty() -> "All movies already have metadata."
                        refreshAll -> "Refreshed ${pending.size} movies."
                        else -> "Metadata updated for ${pending.size} movies."
                    }
                }
            }
        } finally {
            if (active.decrementAndGet() == 0) running.value = false
        }
    }

    /** Uses a {tmdb-123} tag or an earlier match when present, otherwise a title/year search. */
    suspend fun match(movie: MovieEntity) = mutationLock.withLock {
        val current = database.movies().get(movie.id)?.takeIf { needsMetadata(it) && !it.isMissing }
            ?: return@withLock
        matchLocked(current)
    }

    private suspend fun matchLocked(movie: MovieEntity, authorize: () -> Unit = {}) {
        authorize()
        if (MediaFile.isAudio(movie.filePath) || movie.isPhoto) return
        if (movie.metadataFetched && !movie.certificationFetched) {
            val certification = when {
                movie.seriesTmdbId != null -> tmdb.tvDetails(movie.seriesTmdbId).contentRatings?.let { it.usRating to true }
                movie.tmdbId != null -> tmdb.details(movie.tmdbId).releaseDates?.let { it.usRating to true }
                else -> null
            }
            if (movie.seriesTmdbId != null || movie.tmdbId != null) {
                if (certification != null) database.withTransaction {
                    authorize()
                    val current = database.movies().get(movie.id) ?: return@withTransaction
                    if (sameMatch(current, movie)) database.movies().setCertification(movie.id, certification.first)
                }
                return
            }
        }
        movie.episodeInfo?.let { return matchTVLocked(movie, it, authorize) }
        movie.tmdbId?.let { return applyLocked(it, movie.id, authorize = authorize) }
        val title = if (movie.isLocked || movie.hasLocalMetadata) movie.title else movie.parsedTitle
        val year = if (movie.isLocked || movie.hasLocalMetadata) movie.year else movie.parsedYear
        val best = title.takeIf { it.isNotBlank() }?.let { TitleMatcher.bestMatch(it, year, tmdb.search(it, year)) }
        if (best != null) applyLocked(best.id, movie.id, authorize = authorize) else database.withTransaction {
            authorize()
            val current = database.movies().get(movie.id) ?: return@withTransaction
            if (sameMatch(current, movie)) database.movies().markMetadataFetched(movie.id)
        }
    }

    private fun needsMetadata(movie: MovieEntity): Boolean = !movie.isPhoto && (!movie.metadataFetched ||
        (!movie.certificationFetched && (movie.tmdbId != null || movie.seriesTmdbId != null)) ||
        (!movie.isLocked && movie.seriesTitle == null && movie.episodeInfo != null))

    private suspend fun matchTVLocked(movie: MovieEntity, info: EpisodeInfo, authorize: () -> Unit = {}) {
        val id = movie.seriesTmdbId ?: TitleMatcher.bestMatch(info.seriesTitle, info.year,
            tmdb.searchTV(info.seriesTitle, info.year))?.id
        if (id != null) {
            applyTVLocked(id, movie, info, authorize = authorize)
        } else {
            database.withTransaction {
                authorize()
                val current = database.movies().get(movie.id) ?: return@withTransaction
                if (sameMatch(current, movie)) {
                    database.movies().rememberEpisode(movie.id, info.seriesTitle, info.season, info.episode)
                }
            }
        }
    }

    private fun sameMatch(current: MovieEntity, original: MovieEntity): Boolean =
        current.sourceId == original.sourceId && current.filePath == original.filePath &&
        current.title == original.title && current.year == original.year && current.isLocked == original.isLocked &&
            current.tmdbId == original.tmdbId && current.seriesTmdbId == original.seriesTmdbId &&
            current.episodeInfo == original.episodeInfo && !current.isMissing

    suspend fun applyTV(seriesId: Int, movieId: String, force: Boolean = false, authorize: () -> Unit = {}) = mutationLock.withLock {
        authorize()
        val movie = database.movies().get(movieId) ?: return@withLock
        val info = movie.episodeInfo ?: return@withLock
        applyTVLocked(seriesId, movie, info, force, authorize)
    }

    private suspend fun applyTVLocked(seriesId: Int, movie: MovieEntity, info: EpisodeInfo, force: Boolean = false, authorize: () -> Unit = {}) {
        val details = tmdb.tvDetails(seriesId)
        val season = tmdb.tvSeason(seriesId, info.season)
        val episode = season.episodes.firstOrNull { it.seasonNumber == info.season && it.episodeNumber == info.episode }
        database.withTransaction {
            authorize()
            val movies = database.movies()
            val current = movies.get(movie.id) ?: return@withTransaction
            if (!sameMatch(current, movie)) return@withTransaction
            movies.applyTVMetadata(
                id = movie.id, seriesTitle = details.name.ifBlank { info.seriesTitle }, seriesTmdbId = details.id,
                seasonNumber = info.season, episodeNumber = info.episode, seasonPosterPath = season.posterPath,
                overview = episode?.overview?.takeIf { it.isNotBlank() } ?: details.overview,
                runtimeMinutes = episode?.runtime ?: details.episodeRunTime.firstOrNull { it > 0 },
                rating = episode?.voteAverage ?: details.voteAverage, posterPath = details.posterPath,
                backdropPath = episode?.stillPath ?: details.backdropPath, genresJson = converters.fromList(details.genres.orEmpty().map { it.name }),
            )
            val title = episode?.name?.takeIf { it.isNotBlank() } ?: movie.title
            details.contentRatings?.let { movies.setCertification(movie.id, it.usRating) }
            movies.applyMatchedTitle(movie.id, title, WatchRules.sortTitle(title), details.year ?: info.year, force)
            if (force) movies.get(movie.id)?.let {
                movies.update(it.copy(isLocked = true, hasLocalMetadata = false, localMetadataJson = null, edition = null))
            }
            else movies.get(movie.id)?.let { movies.update(LocalMetadataImporter.reapply(it)) }
        }
    }

    /** Stores TMDB details; [force] (manual re-match) also replaces a title the user locked. */
    suspend fun apply(tmdbId: Int, movieId: String, force: Boolean = false, authorize: () -> Unit = {}) = mutationLock.withLock {
        authorize()
        applyLocked(tmdbId, movieId, force, authorize)
    }

    /** Reset and optional fresh match are one user operation relative to in-flight automatic matches. */
    suspend fun resetToFile(movieId: String, authorize: () -> Unit = {}) = mutationLock.withLock {
        authorize()
        val movies = database.movies()
        val movie = movies.get(movieId) ?: return@withLock
        if (movie.isPhoto) return@withLock
        val fromFile = MovieEdits.fromFile(movie.filePath)
        database.withTransaction {
            authorize()
            movies.resetToFile(movieId, fromFile.title, WatchRules.sortTitle(fromFile.title), fromFile.year,
                fromFile.tmdbId, converters.fromList(emptyList()))
        }
        if (!tmdb.hasKey()) return@withLock
        val reset = movies.get(movieId) ?: return@withLock
        try {
            matchLocked(reset, authorize)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            throw MetadataException("Reset to the file name; matching will be retried after the next scan. ${TmdbClient.describe(e)}")
        }
    }

    private suspend fun applyLocked(tmdbId: Int, movieId: String, force: Boolean = false, authorize: () -> Unit = {}) {
        val movies = database.movies()
        val original = movies.get(movieId)?.takeUnless { it.isMissing || it.isPhoto } ?: return
        val details = tmdb.details(tmdbId)
        database.withTransaction {
            authorize()
            val current = movies.get(movieId) ?: return@withTransaction
            if (!sameMatch(current, original)) return@withTransaction
            movies.applyMetadata(
                id = movieId,
                tmdbId = details.id,
                overview = details.overview,
                tagline = details.tagline,
                runtimeMinutes = details.runtime,
                rating = details.voteAverage,
                posterPath = details.posterPath,
                backdropPath = details.backdropPath,
                genresJson = converters.fromList(details.genres.orEmpty().map { it.name }.filter { it.isNotBlank() }),
            )
            details.releaseDates?.let { movies.setCertification(movieId, it.usRating) }
            movies.setFranchise(movieId, details.collection?.id, details.collection?.name?.takeIf { it.isNotBlank() })
            if (details.title.isNotBlank()) {
                movies.applyMatchedTitle(movieId, details.title, WatchRules.sortTitle(details.title), details.year, force)
            }
            if (force) movies.get(movieId)?.let {
                movies.update(it.copy(isLocked = true, hasLocalMetadata = false, localMetadataJson = null, edition = null))
            }
            else movies.get(movieId)?.let { movies.update(LocalMetadataImporter.reapply(it)) }
        }
    }
}
