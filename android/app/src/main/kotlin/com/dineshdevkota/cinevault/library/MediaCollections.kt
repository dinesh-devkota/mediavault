package com.dineshdevkota.cinevault.library

import android.content.Context
import com.dineshdevkota.cinevault.core.MediaKind
import com.dineshdevkota.cinevault.core.MediaVersions
import com.dineshdevkota.cinevault.core.TitleMatcher
import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.family.FamilyLibrary
import com.dineshdevkota.cinevault.family.FamilyStore
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.util.UUID

data class VersionGroup(val id: String, val versions: List<MovieEntity>) {
    val representative: MovieEntity get() = versions.first()
}

fun movieVersionKey(movie: MovieEntity): String {
    if (movie.mediaKind !in setOf(MediaKind.MOVIE, MediaKind.DOCUMENTARY)) return "file:${movie.id}"
    movie.tmdbId?.let { return "tmdb:$it" }
    val year = movie.year ?: return "file:${movie.id}"
    val title = TitleMatcher.normalize(movie.title)
    return if (title.isBlank()) "file:${movie.id}" else "title:$title:$year"
}

/** Caller supplies only currently visible, authorized titles. Keep the first item to preserve sort order. */
fun groupMovieVersions(movies: List<MovieEntity>): List<VersionGroup> = movies.groupBy(::movieVersionKey)
    .map { (key, copies) -> VersionGroup(key, copies) }

fun versionDescription(movie: MovieEntity): String = movie.edition?.takeIf { it.isNotBlank() } ?: MediaVersions.label(movie.filePath)

@Serializable
data class CustomCollection(val id: String = UUID.randomUUID().toString(), val name: String, val movieIds: List<String> = emptyList())

data class MediaCollection(val id: String, val name: String, val movies: List<MovieEntity>, val custom: Boolean)

/** Membership is local to a household profile. Titles, counts and covers are resolved from its live visible library. */
class MediaCollections(context: Context, private val family: FamilyStore, private val library: FamilyLibrary,
    preferenceName: String = "media-collections") {
    private val prefs = context.getSharedPreferences(preferenceName, Context.MODE_PRIVATE)
    private val revision = MutableStateFlow(0)
    private val serializer = ListSerializer(CustomCollection.serializer())
    private fun read(profile: String): List<CustomCollection> = runCatching {
        val text = prefs.getString(profile, "[]").orEmpty()
        require(text.length <= 4 * 1024 * 1024)
        Json.decodeFromString(serializer, text).also { require(it.size <= 500 && it.all { c -> c.movieIds.size <= 10000 }) }
    }.getOrDefault(emptyList())
    private fun write(profile: String, list: List<CustomCollection>) {
        require(list.size <= 500 && list.all { it.movieIds.size <= 10000 }) { "You can keep up to 500 collections with 10,000 files each." }
        val text = Json.encodeToString(serializer, list)
        require(text.toByteArray().size <= 4 * 1024 * 1024) { "Your saved collections are too large. Remove unused collections first." }
        check(prefs.edit().putString(profile, text).commit()) { "Could not save the collection. Try again." }
        revision.value++
    }
    fun observeCustom() = combine(family.session, revision) { session, _ ->
        if (session.unlocked && family.isCurrent(session)) read(session.historyId) else emptyList()
    }
    fun observeAll() = combine(library.observeSnapshot(), revision) { snapshot, _ ->
        val session = snapshot.session
        if (!session.unlocked || !family.isCurrent(session)) emptyList() else {
            val custom = read(session.historyId)
            val available = watchStatusItems(snapshot.movies, snapshot.sources).filter { !it.isHidden && !it.isPhoto && family.permits(it) }
            val byId = available.associateBy { it.id }
            val own = custom.map { c -> MediaCollection(c.id, c.name, c.movieIds.mapNotNull(byId::get), true) }
            val franchises = available.filter { it.episodeInfo == null && !it.franchiseName.isNullOrBlank() }
                .groupBy { it.franchiseId?.let { id -> "tmdb:$id" } ?: "nfo:${TitleMatcher.normalize(it.franchiseName.orEmpty())}" }
                .map { (id, films) -> MediaCollection("franchise:$id", films.first().franchiseName.orEmpty(), films, false) }
            if (family.isCurrent(session)) own + franchises.filter { groupMovieVersions(it.movies).size >= 2 }.sortedBy { it.name.lowercase() } else emptyList()
        }
    }
    suspend fun create(name: String, ids: Collection<String> = emptyList()): String {
        val token = family.current
        check(token.unlocked) { "Choose a profile first." }
        val cleaned = name.trim()
        require(cleaned.length in 1..80) { "Use a collection name with 1 to 80 characters." }
        val authorized = library.forIds(ids.toList()).filter { !it.isHidden && !it.isMissing && !it.isPhoto }.map { it.id }
        check(family.isCurrent(token)) { "The profile changed. Try again." }
        val all = read(token.historyId)
        require(all.none { it.name.equals(cleaned, true) }) { "A collection with this name already exists." }
        val collection = CustomCollection(name = cleaned, movieIds = authorized)
        write(token.historyId, all + collection)
        return collection.id
    }
    suspend fun setMembers(id: String, ids: Collection<String>, add: Boolean) {
        val token = family.current
        val authorized = library.forIds(ids.toList()).filter { !it.isHidden && !it.isMissing && !it.isPhoto }.map { it.id }.toSet()
        check(token.unlocked && family.isCurrent(token)) { "The profile changed. Try again." }
        write(token.historyId, read(token.historyId).map { collection ->
            if (collection.id != id) collection else collection.copy(movieIds = if (add)
                (collection.movieIds + authorized).distinct() else collection.movieIds.filterNot { it in authorized })
        })
    }
    fun rename(id: String, name: String) {
        val token = family.current; check(token.unlocked)
        val cleaned = name.trim(); require(cleaned.length in 1..80) { "Use a collection name with 1 to 80 characters." }
        val all = read(token.historyId); require(all.none { it.id != id && it.name.equals(cleaned, true) }) { "This collection name is already in use." }
        check(family.isCurrent(token)); write(token.historyId, all.map { if (it.id == id) it.copy(name = cleaned) else it })
    }
    fun delete(id: String) {
        val token = family.current; check(token.unlocked && family.isCurrent(token))
        write(token.historyId, read(token.historyId).filterNot { it.id == id })
    }
}
