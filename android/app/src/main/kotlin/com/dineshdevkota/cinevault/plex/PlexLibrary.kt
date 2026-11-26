package com.dineshdevkota.cinevault.plex

import androidx.room.withTransaction
import com.dineshdevkota.cinevault.core.WatchRules
import com.dineshdevkota.cinevault.data.CineVaultDatabase
import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.data.SecretBox
import com.dineshdevkota.cinevault.data.SourceEntity
import com.dineshdevkota.cinevault.family.FamilyPolicy
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.UUID

internal const val PLEX = "plex"
internal val plexLibraryTypes = setOf("movie", "show", "photo")

internal suspend fun SourceEntity.plexClient(secrets: SecretBox, exchange: PlexExchange = PlexHTTP): PlexMediaClient {
    require(sourceType == PLEX && username.isNotBlank())
    val token = withContext(Dispatchers.IO) { secrets.decrypt(encryptedPassword) }
    if (token.isBlank()) throw PlexException("Reconnect Plex from Sources.")
    val connection = PlexAccountClient.Connection(host, local = false, relay = false)
    val server = PlexAccountClient.Server(name, username, "server", token, listOf(connection))
    return PlexMediaClient(server, connection, UUID.fromString(id), exchange)
}

private val plexMediaPath = Regex("""plex/(?:movies/[0-9]{1,20}\.mp4|shows/[0-9]{1,20}/[0-9]{1,20}\.mp4|photos/[0-9]{1,20}\.jpg)""")

internal fun plexItemId(path: String): String? =
    path.takeIf(plexMediaPath::matches)?.substringAfterLast('/')?.substringBeforeLast('.')

internal fun plexSeriesId(path: String): String? =
    path.takeIf { it.startsWith("plex/shows/") && plexMediaPath.matches(it) }?.split('/')?.get(2)

internal class PlexAuthorizedItem(val item: PlexMediaClient.Item, val rating: String?)

internal suspend fun PlexMediaClient.authorizedItem(
    movie: MovieEntity,
    libraryId: String,
    authorize: (MovieEntity) -> Unit,
): PlexAuthorizedItem {
    val id = plexItemId(movie.filePath) ?: throw PlexException("This Plex item is invalid.")
    authorize(movie)
    val item = item(id, libraryId)
    val seriesId = plexSeriesId(movie.filePath)
    val rating = when {
        movie.isPhoto && item.type == "photo" -> null
        seriesId != null && item.type == "episode" && item.grandparentRatingKey?.content == seriesId -> {
            authorize(movie)
            val series = this.item(seriesId, libraryId)
            if (series.type != "show") throw PlexException("This Plex show has changed. Rescan its source.")
            series.contentRating
        }
        seriesId == null && !movie.isPhoto && item.type == "movie" -> item.contentRating
        else -> throw PlexException("This item no longer matches the Plex catalog. Rescan its source.")
    }
    val ratings = if (seriesId == null) FamilyPolicy.movieRatings else FamilyPolicy.tvRatings
    val accepted = rating?.takeIf { FamilyPolicy.allowsRating(it, ratings.last(), seriesId != null) }
    authorize(movie.copy(ageCertification = accepted))
    return PlexAuthorizedItem(item, accepted)
}

internal data class PlexCatalogEntry(
    val item: PlexMediaClient.Item,
    val series: PlexMediaClient.Item? = null,
    val season: PlexMediaClient.Item? = null,
) {
    val path: String get() = when {
        series != null -> "plex/shows/${series.ratingKey}/${item.ratingKey}.mp4"
        item.type == "photo" -> "plex/photos/${item.ratingKey}.jpg"
        else -> "plex/movies/${item.ratingKey}.mp4"
    }

    fun record(sourceId: String, existing: MovieEntity?): MovieEntity? {
        val title = item.title.trim().takeIf(String::isNotEmpty) ?: return null
        val photo = item.type == "photo"
        val episode = item.type == "episode"
        val seriesTitle = series?.title?.trim()
        val seasonNumber = season?.index ?: item.parentIndex
        if (episode && (seriesTitle.isNullOrEmpty() || seasonNumber?.let { it in 0..999 } != true ||
                item.index?.let { it in 0..999 } != true)) return null
        val rating = if (episode) series?.contentRating else item.contentRating
        val accepted = if (episode) FamilyPolicy.tvRatings else FamilyPolicy.movieRatings
        val duration = item.duration?.takeIf { it > 0 } ?: 0
        val tmdb = (series ?: item).guids.firstNotNullOfOrNull { guid ->
            guid.id.takeIf { it.startsWith("tmdb://") }?.removePrefix("tmdb://")?.toIntOrNull()?.takeIf { it > 0 }
        }
        val name = "$title.${if (photo) "jpg" else "mp4"}"
        val base = existing ?: MovieEntity(
            sourceId = sourceId, filePath = path, fileName = name, fileSize = 0, parsedTitle = title,
            parsedYear = item.year, title = title, year = item.year,
        )
        return base.copy(
            fileName = name,
            parsedTitle = title,
            parsedYear = item.year,
            title = if (base.isLocked) base.title else title,
            sortTitle = if (base.isLocked) base.sortTitle else WatchRules.sortTitle(title),
            year = if (base.isLocked) base.year else item.year,
            overview = item.summary,
            tmdbId = if (episode || photo) null else base.tmdbId.takeIf { base.isLocked } ?: tmdb,
            seriesTmdbId = if (episode) base.seriesTmdbId.takeIf { base.isLocked } ?: tmdb else null,
            ageCertification = rating?.takeIf { !photo && FamilyPolicy.allowsRating(it, accepted.last(), episode) },
            certificationFetched = true,
            metadataFetched = true,
            runtimeMinutes = (duration / 60_000L).takeIf { it in 1..Int.MAX_VALUE.toLong() }?.toInt(),
            durationMs = base.durationMs.takeIf { it > 0 } ?: duration,
            seriesTitle = seriesTitle.takeIf { episode },
            seasonNumber = seasonNumber.takeIf { episode },
            episodeNumber = item.index.takeIf { episode },
            isMissing = false,
        )
    }
}

internal suspend fun PlexMediaClient.libraryEntries(
    library: PlexMediaClient.Library,
    progress: (Int) -> Unit,
): List<PlexCatalogEntry> {
    val entries = ArrayList<PlexCatalogEntry>()
    suspend fun add(entry: PlexCatalogEntry) {
        if (entries.size == 250_000) throw PlexException("This Plex library exceeds the catalog limit.")
        entries.add(entry)
    }
    catalog(library) { page ->
        for (item in page) {
            when {
                library.type == "movie" && item.type == "movie" -> add(PlexCatalogEntry(item))
                library.type == "photo" && item.type == "photo" -> add(PlexCatalogEntry(item))
                library.type == "show" && item.type == "show" -> children(item) { seasons ->
                    for (season in seasons) {
                        if (season.type != "season") continue
                        children(season) { episodes ->
                            for (episode in episodes) {
                                if (episode.type == "episode") add(PlexCatalogEntry(episode, item, season))
                            }
                        }
                    }
                }
            }
        }
        progress(entries.size)
    }
    if (entries.map(PlexCatalogEntry::path).distinct().size != entries.size) {
        throw PlexException("Plex returned the same catalog item more than once.")
    }
    return entries
}

internal suspend fun importPlexLibrary(
    database: CineVaultDatabase,
    source: SourceEntity,
    secrets: SecretBox,
    exchange: PlexExchange = PlexHTTP,
    progress: (Int) -> Unit,
): Pair<Int, Int>? {
    val client = source.plexClient(secrets, exchange)
    val library = client.libraries().singleOrNull { it.key == source.share && it.type in plexLibraryTypes }
        ?: throw PlexException("The saved Plex library is no longer available. Reconnect it in Sources.")
    val entries = client.libraryEntries(library, progress)
    return database.withTransaction {
        val current = database.sources().get(source.id)
        if (current?.copy(name = source.name, lastScanAt = source.lastScanAt) != source) return@withTransaction null
        val dao = database.movies()
        val previous = dao.forSource(source.id).associateBy { it.filePath }.toMutableMap()
        var added = 0
        var total = 0
        for (entry in entries) {
            val old = previous[entry.path]
            val record = entry.record(source.id, old) ?: continue
            previous.remove(entry.path)
            if (old == null) { dao.insert(record); added++ } else dao.update(record)
            total++
        }
        previous.values.forEach { dao.markMissing(it.id) }
        database.sources().setLastScan(source.id, System.currentTimeMillis())
        total to added
    }
}
