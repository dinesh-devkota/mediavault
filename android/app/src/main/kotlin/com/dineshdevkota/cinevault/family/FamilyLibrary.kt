package com.dineshdevkota.cinevault.family

import androidx.room.withTransaction
import com.dineshdevkota.cinevault.data.CineVaultDatabase
import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.data.ProfileHistory
import com.dineshdevkota.cinevault.data.SourceEntity
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine

data class FamilyLibrarySnapshot(val session: FamilySession, val movies: List<MovieEntity>, val sources: List<SourceEntity>)

/** The only user-facing read/write path; scanner and metadata retain the shared index. */
class FamilyLibrary(private val database: CineVaultDatabase, val family: FamilyStore) {
    private val movies = database.movies()
    private val history = database.profileHistory()
    private fun project(movie: MovieEntity, state: ProfileHistory?): MovieEntity = movie.copy(
        isWatched = state?.watched ?: false, isWatchlisted = state?.watchlisted ?: false,
        playbackPositionMs = state?.positionMs ?: 0, durationMs = state?.durationMs ?: 0,
        lastPlayedAt = state?.lastPlayedAt, isHidden = state?.hidden ?: false,
    )
    /** Keep source visibility and profile history attached to the exact session that produced them. */
    fun observeSnapshot(): Flow<FamilyLibrarySnapshot> = combine(movies.observeAll(), history.observeAll(),
        database.sources().observeAll(), family.session) { all, states, sources, session ->
        if (!session.unlocked || !family.isCurrent(session)) FamilyLibrarySnapshot(session, emptyList(), emptyList())
        else {
            val own = states.filter { it.profileId == session.historyId }.associateBy { it.movieId }
            val visible = all.filter { allows(session, it) }.map { if (session.admin) it else project(it, own[it.id]) }
            val visibleSources = if (session.admin) sources else sources.filter { source ->
                session.profile?.folders?.any { it.sourceId == source.id } == true
            }
            if (family.isCurrent(session)) FamilyLibrarySnapshot(session, visible, visibleSources)
            else FamilyLibrarySnapshot(session, emptyList(), emptyList())
        }
    }
    fun observeAll(): Flow<List<MovieEntity>> = combine(movies.observeAll(), history.observeAll(), family.session) { all, states, session ->
        if (!session.unlocked) emptyList() else {
            val own = states.filter { it.profileId == session.historyId }.associateBy { it.movieId }
            val visible = all.filter { !session.enabled || session.profile?.let { p -> FamilyPolicy.allows(p, it) } == true }
                .map { if (session.admin) it else project(it, own[it.id]) }
            if (family.isCurrent(session)) visible else emptyList()
        }
    }
    fun observeSources() = combine(database.sources().observeAll(), family.session) { sources, session ->
        when { !session.unlocked -> emptyList(); session.admin -> sources
            else -> sources.filter { source -> session.profile?.folders?.any { it.sourceId == source.id } == true } }
    }
    fun observe(id: String): Flow<MovieEntity?> = combine(movies.observe(id), history.observeMovie(id), family.session) { movie, states, token ->
        if (movie == null || !family.isCurrent(token) || !allows(token, movie)) null
        else if (token.admin) movie else project(movie, states.firstOrNull { it.profileId == token.historyId })
    }
    private fun allows(token: FamilySession, movie: MovieEntity): Boolean = token.unlocked &&
        (!token.enabled || token.profile?.let { FamilyPolicy.allows(it, movie) } == true)
    suspend fun get(id: String): MovieEntity? {
        val token = family.current
        val movie = movies.get(id)?.takeIf(family::permits) ?: return null
        val result = if (token.admin) movie else project(movie, history.get(token.historyId, id))
        return result.takeIf { family.isCurrent(token) && family.permits(it) }
    }
    private suspend fun projectBatch(token: FamilySession, all: List<MovieEntity>): List<MovieEntity> {
        if (!family.isCurrent(token)) return emptyList()
        val own = if (token.admin) emptyMap() else history.forProfile(token.historyId).associateBy { it.movieId }
        val visible = all.filter { allows(token, it) }.map { if (token.admin) it else project(it, own[it.id]) }
        return if (family.isCurrent(token)) visible else emptyList()
    }
    suspend fun available(): List<MovieEntity> {
        val token = family.current
        return projectBatch(token, movies.available())
    }
    suspend fun forIds(ids: List<String>): List<MovieEntity> {
        val token = family.current
        return projectBatch(token, movies.forIds(ids))
    }

    private suspend fun change(id: String, token: FamilySession, owner: suspend () -> Unit, edit: (ProfileHistory) -> ProfileHistory) {
        database.withTransaction {
            val movie = movies.get(id) ?: return@withTransaction
            if (!family.isCurrent(token) || !family.permits(movie)) return@withTransaction
            if (token.admin) owner() else {
                val current = history.get(token.historyId, id) ?: ProfileHistory(token.historyId, id)
                if (family.isCurrent(token)) history.upsert(edit(current))
            }
        }
    }
    suspend fun setWatched(id: String, watched: Boolean, token: FamilySession = family.current) = change(id, token,
        { movies.setWatched(id, watched) }, { it.copy(watched = watched, positionMs = 0) })
    suspend fun setWatched(ids: List<String>, watched: Boolean, token: FamilySession = family.current): Int {
        var changed = 0
        ids.forEach { if (family.isCurrent(token) && get(it) != null) { setWatched(it, watched, token); changed++ } }
        return changed
    }
    suspend fun setWatchlisted(id: String, value: Boolean, token: FamilySession = family.current) = change(id, token,
        { movies.setWatchlisted(id, value) }, { it.copy(watchlisted = value) })
    suspend fun setHidden(id: String, value: Boolean, token: FamilySession = family.current) = change(id, token,
        { movies.setHidden(id, value) }, { it.copy(hidden = value) })
    suspend fun saveProgress(id: String, position: Long, duration: Long, playedAt: Long, token: FamilySession) = change(id, token,
        { movies.saveProgress(id, position, duration, playedAt) },
        { it.copy(watched = false, positionMs = position, durationMs = duration.takeIf { d -> d > 0 } ?: it.durationMs, lastPlayedAt = playedAt) })
    suspend fun markFinished(id: String, duration: Long, playedAt: Long, token: FamilySession) = change(id, token,
        { movies.markFinished(id, duration, playedAt) },
        { it.copy(watched = true, positionMs = 0, durationMs = duration.takeIf { d -> d > 0 } ?: it.durationMs, lastPlayedAt = playedAt) })

    /** Captured while playing is authorized; queued final saves belong to that profile even after background lock. */
    fun playbackCheckpoint(movie: MovieEntity, token: FamilySession, position: Long, duration: Long,
        playedAt: Long, finished: Boolean): (suspend () -> Unit)? {
        if (!family.isCurrent(token) || !allows(token, movie)) return null
        return {
            database.withTransaction {
                val current = movies.get(movie.id)
                if (current != null && current.sourceId == movie.sourceId && current.filePath == movie.filePath) {
                    if (token.admin) {
                        if (finished) movies.markFinished(movie.id, duration, playedAt)
                        else movies.saveProgress(movie.id, position, duration, playedAt)
                    } else if (family.profiles.any { it.id == token.historyId }) {
                        val own = history.get(token.historyId, movie.id) ?: ProfileHistory(token.historyId, movie.id)
                        history.upsert(own.copy(watched = finished, positionMs = if (finished) 0 else position,
                            durationMs = duration.takeIf { it > 0 } ?: own.durationMs, lastPlayedAt = playedAt))
                    }
                }
            }
        }
    }
}
