package com.dineshdevkota.cinevault.jellyfin

import androidx.room.withTransaction
import com.dineshdevkota.cinevault.BuildConfig
import com.dineshdevkota.cinevault.core.WatchRules
import com.dineshdevkota.cinevault.data.CineVaultDatabase
import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.data.SecretBox
import com.dineshdevkota.cinevault.data.SourceEntity
import com.dineshdevkota.cinevault.family.FamilyPolicy
import com.dineshdevkota.cinevault.webdav.DavAddress
import okhttp3.OkHttpClient

internal const val JELLYFIN = "jellyfin"

internal class JellyfinConnection(val client: JellyfinClient, val session: JellyfinSession)

internal fun SourceEntity.jellyfinConnection(secrets: SecretBox, fixtureHttp: OkHttpClient? = null): JellyfinConnection {
    require(sourceType == JELLYFIN && username.isNotBlank())
    val token = secrets.decrypt(encryptedPassword)
    if (token.isBlank()) throw JellyfinException("Reconnect this Jellyfin source in Sources.")
    val client = if (fixtureHttp == null) JellyfinClient(host, id, BuildConfig.VERSION_NAME)
        else JellyfinClient(host, id, BuildConfig.VERSION_NAME, http = fixtureHttp)
    return JellyfinConnection(client, JellyfinSession(token, JellyfinUser(username, "")))
}

internal fun jellyfinEndpoint(raw: String): String =
    try { DavAddress(raw).base.toString() }
    catch (_: IllegalArgumentException) {
        throw IllegalArgumentException("Enter a complete Jellyfin HTTPS address without credentials, a query, or a fragment.")
    }

internal fun jellyfinItemID(path: String): String? =
    path.takeIf { it.startsWith("jellyfin/") && it.endsWith(".mp4") }
        ?.removePrefix("jellyfin/")?.removeSuffix(".mp4")?.takeIf { DavAddress.safeComponent(it) }

internal fun jellyfinPhotoID(path: String): String? =
    path.takeIf { it.startsWith("jellyfin/") && it.endsWith(".jpg") }
        ?.removePrefix("jellyfin/")?.removeSuffix(".jpg")?.takeIf { DavAddress.safeComponent(it) }

private fun jellyfinPhoto(sourceId: String, item: JellyfinItem, old: MovieEntity?): MovieEntity? {
    if (!DavAddress.safeComponent(item.id)) throw JellyfinException("Jellyfin returned an invalid item identifier.")
    val title = item.name.trim().takeIf(String::isNotEmpty) ?: return null
    val record = old ?: MovieEntity(
        sourceId = sourceId, filePath = "jellyfin/${item.id}.jpg", fileName = "$title.jpg", fileSize = 0,
        parsedTitle = title, parsedYear = item.year, title = title, year = item.year,
    )
    return record.copy(
        fileName = "$title.jpg",
        parsedTitle = title,
        parsedYear = item.year,
        title = if (record.isLocked) record.title else title,
        sortTitle = if (record.isLocked) record.sortTitle else WatchRules.sortTitle(title),
        year = if (record.isLocked) record.year else item.year,
        metadataFetched = true,
        isMissing = false,
    )
}

internal fun jellyfinMovie(
    sourceId: String,
    item: JellyfinItem,
    series: JellyfinItem?,
    old: MovieEntity? = null,
): MovieEntity? {
    if (item.type != "Movie" && item.type != "Episode") return null
    if (!DavAddress.safeComponent(item.id)) throw JellyfinException("Jellyfin returned an invalid item identifier.")
    val episode = item.type == "Episode"
    val seriesName = if (episode) series?.name ?: item.seriesName else null
    // An incompletely described episode must not fall through the movie rating policy.
    if (episode && (seriesName.isNullOrBlank() || item.seasonNumber?.let { it in 0..999 } != true || item.indexNumber?.let { it in 0..999 } != true)) return null
    val rating = if (episode) series?.rating else item.rating
    val knownRatings = if (episode) FamilyPolicy.tvRatings else FamilyPolicy.movieRatings
    val title = item.name.trim().takeIf(String::isNotEmpty) ?: return null
    val runtime = item.runtimeTicks?.takeIf { it > 0 } ?: 0L
    val path = "jellyfin/${item.id}.mp4"
    val record = old ?: MovieEntity(
        sourceId = sourceId, filePath = path, fileName = "$title.mp4", fileSize = 0,
        parsedTitle = title, parsedYear = item.year, title = title, year = item.year,
    )
    return record.copy(
        fileName = "$title.mp4",
        parsedTitle = title,
        parsedYear = item.year,
        title = if (record.isLocked) record.title else title,
        sortTitle = if (record.isLocked) record.sortTitle else WatchRules.sortTitle(title),
        year = if (record.isLocked) record.year else item.year,
        overview = item.overview,
        ageCertification = rating?.takeIf { FamilyPolicy.allowsRating(it, knownRatings.last(), episode) },
        certificationFetched = true,
        metadataFetched = true,
        runtimeMinutes = (runtime / 600_000_000L).takeIf { it in 1..Int.MAX_VALUE.toLong() }?.toInt(),
        durationMs = record.durationMs.takeIf { it > 0 } ?: runtime / 10_000L,
        seriesTitle = seriesName,
        seasonNumber = item.seasonNumber.takeIf { episode },
        episodeNumber = item.indexNumber.takeIf { episode },
        isMissing = false,
    )
}

internal suspend fun importJellyfinLibrary(
    database: CineVaultDatabase,
    source: SourceEntity,
    secrets: SecretBox,
    fixtureHttp: OkHttpClient? = null,
    onProgress: (Int) -> Unit,
): Pair<Int, Int>? {
    val connection = source.jellyfinConnection(secrets, fixtureHttp)
    val catalog = mutableListOf<JellyfinItem>()
    connection.client.catalog(connection.session, source.share) { page ->
        catalog.addAll(page)
        onProgress(catalog.size)
    }
    val series = catalog.filter { it.type == "Series" }.associateBy { it.id }
    // Only a complete, validated catalog can make a previously present item missing.
    return database.withTransaction {
        val current = database.sources().get(source.id)
        if (current?.copy(name = source.name) != source) return@withTransaction null
        val dao = database.movies()
        val previous = dao.forSource(source.id).associateBy { it.filePath }.toMutableMap()
        var total = 0
        var added = 0
        for (item in catalog) {
            val path = if (item.type == "Photo") "jellyfin/${item.id}.jpg" else "jellyfin/${item.id}.mp4"
            val prior = previous[path]
            val result = if (item.type == "Photo") jellyfinPhoto(source.id, item, prior)
                else jellyfinMovie(source.id, item, item.seriesId?.let { series[it] }, prior)
            if (result == null) continue
            previous.remove(path)
            if (prior == null) { dao.insert(result); added++ }
            else dao.update(result)
            total++
        }
        for (missing in previous.values) dao.markMissing(missing.id)
        database.sources().setLastScan(source.id, System.currentTimeMillis())
        total to added
    }
}
