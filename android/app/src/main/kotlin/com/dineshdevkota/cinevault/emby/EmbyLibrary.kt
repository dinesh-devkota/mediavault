package com.dineshdevkota.cinevault.emby

import androidx.room.withTransaction
import com.dineshdevkota.cinevault.BuildConfig
import com.dineshdevkota.cinevault.core.WatchRules
import com.dineshdevkota.cinevault.data.CineVaultDatabase
import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.data.SecretBox
import com.dineshdevkota.cinevault.data.SourceEntity
import com.dineshdevkota.cinevault.family.FamilyPolicy
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient

internal const val EMBY = "emby"
private val identifierPattern = Regex("[A-Za-z0-9_.-]{1,256}")

internal fun validEmbyIdentifier(value: String): Boolean =
    value != "." && value != ".." && identifierPattern.matches(value)

internal fun embyEndpoint(raw: String): String =
    requireNotNull(raw.trim().toHttpUrlOrNull()?.takeIf { address ->
        address.isHttps && address.username.isEmpty() && address.password.isEmpty() &&
            address.query == null && address.fragment == null
    }) { "Enter a complete Emby HTTPS address without credentials, a query, or a fragment." }.toString()

internal class EmbyConnection(val client: EmbyClient, val account: EmbyClient.Account)

internal fun SourceEntity.embyConnection(secrets: SecretBox, fixtureHttp: OkHttpClient? = null): EmbyConnection {
    require(sourceType == EMBY && validEmbyIdentifier(username))
    val token = secrets.decrypt(encryptedPassword)
    if (!validEmbyIdentifier(token)) throw EmbyException("Reconnect this Emby source in Sources.")
    val client = if (fixtureHttp == null) EmbyClient(host, id, BuildConfig.VERSION_NAME)
        else EmbyClient(host, id, BuildConfig.VERSION_NAME, fixtureHttp, allowLoopbackHttp = true)
    return EmbyConnection(client, EmbyClient.Account(token, EmbyClient.User(username, "")))
}

internal fun embyItemId(path: String): String? =
    path.takeIf { it.startsWith("emby/") && it.endsWith(".mp4") }
        ?.removePrefix("emby/")?.removeSuffix(".mp4")?.takeIf(::validEmbyIdentifier)

private fun EmbyClient.Item?.subtitleIdentity(): Int? =
    this?.ProviderIds?.entries?.firstOrNull { it.key.equals("Tmdb", ignoreCase = true) }
        ?.value?.toIntOrNull()?.takeIf { it > 0 }

private fun embyPath(id: String) = "emby/$id.mp4"

internal fun embyMovie(sourceId: String, item: EmbyClient.Item, series: EmbyClient.Item?, prior: MovieEntity?): MovieEntity? {
    if (item.Type != "Movie" && item.Type != "Episode") return null
    if (!validEmbyIdentifier(item.Id)) throw EmbyException("Emby returned an invalid item identifier.")
    val episode = item.Type == "Episode"
    val seriesName = if (episode) series?.Name ?: item.SeriesName else null
    if (episode && (seriesName.isNullOrBlank() || item.ParentIndexNumber?.let { it in 0..999 } != true ||
            item.IndexNumber?.let { it in 0..999 } != true)) return null
    val rating = if (episode) series?.OfficialRating else item.OfficialRating
    val ratingLimit = if (episode) FamilyPolicy.tvRatings.last() else FamilyPolicy.movieRatings.last()
    val title = item.Name.trim().takeIf(String::isNotEmpty) ?: return null
    val runtime = item.RunTimeTicks?.takeIf { it > 0 } ?: 0L
    val movie = prior ?: MovieEntity(
        sourceId = sourceId, filePath = embyPath(item.Id), fileName = "$title.mp4", fileSize = 0,
        parsedTitle = title, parsedYear = item.ProductionYear, title = title, year = item.ProductionYear,
    )
    return movie.copy(
        fileName = "$title.mp4",
        parsedTitle = title,
        parsedYear = item.ProductionYear,
        title = if (movie.isLocked) movie.title else title,
        sortTitle = if (movie.isLocked) movie.sortTitle else WatchRules.sortTitle(title),
        year = if (movie.isLocked) movie.year else item.ProductionYear,
        overview = item.Overview,
        tmdbId = if (episode) null else if (movie.isLocked) movie.tmdbId else item.subtitleIdentity(),
        seriesTmdbId = if (!episode) null else if (movie.isLocked) movie.seriesTmdbId else series.subtitleIdentity(),
        seriesTitle = seriesName,
        seasonNumber = item.ParentIndexNumber.takeIf { episode },
        episodeNumber = item.IndexNumber.takeIf { episode },
        ageCertification = rating?.takeIf { FamilyPolicy.allowsRating(it, ratingLimit, episode) },
        certificationFetched = true,
        metadataFetched = true,
        runtimeMinutes = (runtime / 600_000_000L).takeIf { it in 1..Int.MAX_VALUE.toLong() }?.toInt(),
        durationMs = movie.durationMs.takeIf { it > 0 } ?: runtime / 10_000L,
        isMissing = false,
    )
}

internal suspend fun importEmbyLibrary(
    database: CineVaultDatabase,
    source: SourceEntity,
    secrets: SecretBox,
    fixtureHttp: OkHttpClient? = null,
    onProgress: (Int) -> Unit = {},
): Pair<Int, Int>? {
    val connection = source.embyConnection(secrets, fixtureHttp)
    val catalog = mutableListOf<EmbyClient.Item>()
    connection.client.catalog(connection.account, source.share) { page ->
        catalog.addAll(page)
        onProgress(catalog.size)
    }
    val series = catalog.filter { it.Type == "Series" }.associateBy { it.Id }
    return database.withTransaction {
        val current = database.sources().get(source.id)
        if (current?.copy(name = source.name) != source) return@withTransaction null
        val dao = database.movies()
        val previous = dao.forSource(source.id).associateBy { it.filePath }.toMutableMap()
        var total = 0
        var added = 0
        for (item in catalog) {
            val path = embyPath(item.Id)
            val prior = previous[path]
            val movie = embyMovie(source.id, item, item.SeriesId?.let { series[it] }, prior) ?: continue
            previous.remove(path)
            if (prior == null) {
                dao.insert(movie)
                added++
            } else {
                dao.update(movie)
            }
            total++
        }
        previous.values.forEach { dao.markMissing(it.id) }
        database.sources().setLastScan(source.id, System.currentTimeMillis())
        total to added
    }
}
