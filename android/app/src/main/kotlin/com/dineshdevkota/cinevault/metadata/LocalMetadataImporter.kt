package com.dineshdevkota.cinevault.metadata

import androidx.room.withTransaction
import com.dineshdevkota.cinevault.cloud.ONEDRIVE
import com.dineshdevkota.cinevault.core.LocalMediaMetadata
import com.dineshdevkota.cinevault.core.LocalMetadataParser
import com.dineshdevkota.cinevault.core.MediaFile
import com.dineshdevkota.cinevault.core.WatchRules
import com.dineshdevkota.cinevault.data.CineVaultDatabase
import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.data.SecretBox
import com.dineshdevkota.cinevault.data.SourceEntity
import com.dineshdevkota.cinevault.smb.NasBrowser
import com.dineshdevkota.cinevault.smb.NasEntry
import com.dineshdevkota.cinevault.smb.RemoteHandle
import com.dineshdevkota.cinevault.smb.SmbService
import com.dineshdevkota.cinevault.smb.SourceConfig
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.withContext
import kotlin.coroutines.coroutineContext

/** Optional sidecars are imported before online matching. Failed sidecars never delete a title. */
class LocalMetadataImporter(private val database: CineVaultDatabase, private val secrets: SecretBox,
    private val list: suspend (SourceConfig) -> List<NasEntry> = NasBrowser()::listEntries,
    private val open: (SourceConfig, String) -> RemoteHandle = SmbService()::open) {
    suspend fun importSource(sourceId: String) = withContext(Dispatchers.IO) {
        val source = database.sources().get(sourceId) ?: return@withContext
        if (source.sourceType !in setOf("smb", "webdav", ONEDRIVE)) return@withContext
        val config = source.config(secrets)
        val media = database.movies().forSource(sourceId).filter { !it.isMissing && !it.isPhoto && !MediaFile.isAudio(it.filePath) }
        val byFolder = media.groupBy { it.filePath.substringBeforeLast('/', "") }
        val listings = mutableMapOf<String, List<NasEntry>>()
        val failedFolders = mutableSetOf<String>()
        val failedMetadata = mutableSetOf<String>()
        val invalidMetadata = mutableSetOf<String>()
        val parsed = mutableMapOf<String, LocalMediaMetadata?>()
        val artwork = mutableSetOf<String>()
        suspend fun entries(folder: String): List<NasEntry> {
            listings[folder]?.let { return it }
            val result = try {
                list(config.copy(rootPath = folder)).also { require(it.size <= 10000) }
            }
            catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) { failedFolders += folder; emptyList() }
            listings[folder] = result; return result
        }
        suspend fun find(folder: String, candidates: List<String>): String? {
            val names = entries(folder).filterNot { it.isDirectory }.map { it.name }
            var preferred: String? = null
            for (candidate in candidates) {
                val name = names.firstOrNull { it == candidate }
                    ?: if (!config.caseSensitivePaths) names.firstOrNull { it.equals(candidate, ignoreCase = true) } else null
                if (name != null) {
                    val path = listOf(folder, name).filter(String::isNotEmpty).joinToString("/")
                    if (source.includesFile(path)) {
                        if (preferred == null) preferred = path
                        if (MediaFile.isPhoto(path)) artwork += path
                    }
                }
            }
            return preferred
        }
        suspend fun metadata(path: String?): LocalMediaMetadata? {
            if (path == null) return null
            if (parsed.containsKey(path)) return parsed[path]
            val result = try {
                val job = coroutineContext
                val bytes = runInterruptible {
                    open(config, path).use { file ->
                        if (file.length !in 1..LocalMetadataParser.MAX_BYTES.toLong()) return@use null
                        val output = ByteArray(file.length.toInt())
                        file.stream(0).use { input ->
                            var offset = 0
                            while (offset < output.size) {
                                job.ensureActive()
                                val read = input.read(output, offset, output.size - offset)
                                check(read > 0); offset += read
                            }
                        }
                        output
                    }
                }
                // A completed but invalid read is confirmed absence of usable overrides. Only transport
                // failures retain old values; corrupt XML must not leave a stale permissive age rating.
                bytes?.let { try { LocalMetadataParser.parse(it) } catch (_: Exception) { null } }
            } catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) { failedMetadata += path; null }
            if (result == null && path !in failedMetadata) invalidMetadata += path
            parsed[path] = result; return result
        }
        fun images(vararg names: String) = names.flatMap { listOf("$it.jpg", "$it.png", "$it.jpeg", "$it.webp") }
        for ((folder, titles) in byFolder) for (movie in titles) {
            coroutineContext.ensureActive()
            val applicableSidecars = mutableSetOf<String>()
            suspend fun readSidecar(path: String?): LocalMediaMetadata? {
                if (path != null) applicableSidecars += path
                return metadata(path)
            }
            val stem = movie.fileName.substringBeforeLast('.')
            val detailsPath = find(folder, listOf("$stem.nfo", "$stem.xml") + if (titles.size == 1) listOf("movie.nfo", "movie.xml") else emptyList())
            val details = readSidecar(detailsPath)
            val episode = movie.episodeInfo != null || details?.kind == "episodedetails"
            val parent = folder.substringBeforeLast('/', "")
            val parentWithinSource = parent == source.rootPath || (source.rootPath.isEmpty() || parent.startsWith(source.rootPath + "/", !config.caseSensitivePaths))
            val show = if (episode) readSidecar(find(folder, listOf("tvshow.nfo")))
                ?: if (parentWithinSource) readSidecar(find(parent, listOf("tvshow.nfo"))) else null else null
            val season = if (episode) readSidecar(find(folder, listOf("season.nfo"))) else null
            val ownPoster = find(folder, images("$stem-poster", stem))
            val folderPoster = if (titles.size == 1 || episode) find(folder, images("poster", "folder")) else null
            val seriesPoster = if (episode && parentWithinSource) find(parent, images("poster", "folder")) else null
            val ownBackdrop = find(folder, images("$stem-fanart"))
            val folderBackdrop = if (titles.size == 1 || episode) find(folder, images("fanart")) else null
            val seriesBackdrop = if (episode && parentWithinSource) find(parent, images("fanart")) else null
            val seasonNumber = details?.season ?: season?.season ?: movie.episodeInfo?.season
            val seasonPoster = if (episode && parentWithinSource && seasonNumber != null)
                find(parent, images("season${seasonNumber.toString().padStart(2, '0')}-poster", "season$seasonNumber-poster")) ?: folderPoster else null
            val poster = if (episode) seriesPoster ?: folderPoster ?: ownPoster else ownPoster ?: folderPoster
            val backdrop = ownBackdrop ?: ownPoster?.takeIf { episode } ?: folderBackdrop ?: seriesBackdrop
            artwork.addAll(listOfNotNull(ownPoster, folderPoster, seriesPoster, ownBackdrop, folderBackdrop, seriesBackdrop, seasonPoster))
            database.withTransaction {
                if (!sameConnection(source, database.sources().get(sourceId))) return@withTransaction
                val current = database.movies().get(movie.id) ?: return@withTransaction
                if (current.filePath != movie.filePath || current.sourceId != source.id || current.isMissing) return@withTransaction
                val complete = folder !in failedFolders && (!episode || !parentWithinSource || parent !in failedFolders) &&
                    failedMetadata.none { it.substringBeforeLast('/', "") == folder || (episode && it.substringBeforeLast('/', "") == parent) }
                val updated = apply(current, details, show, season, metadataComplete = complete,
                    invalidSidecar = applicableSidecars.any { it in invalidMetadata })
                if (complete) database.movies().update(updated.copy(localPosterPath = poster, localBackdropPath = backdrop, localSeasonPosterPath = seasonPoster))
                else {
                    if (updated != current) database.movies().update(updated)
                    artwork.addAll(listOfNotNull(current.localPosterPath, current.localBackdropPath, current.localSeasonPosterPath))
                }
            }
        }
        database.withTransaction {
            if (!sameConnection(source, database.sources().get(sourceId))) return@withTransaction
            // Suppress only artwork positively associated with an indexed video, never a photo by name alone.
            if (artwork.isNotEmpty()) database.movies().forSource(sourceId).filter { it.isPhoto && it.filePath in artwork }
                .forEach { database.movies().markMissing(it.id) }
        }
    }

    companion object {
        private val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
        private fun sameConnection(original: SourceEntity, current: SourceEntity?): Boolean = current != null &&
            current.copy(name = original.name, lastScanAt = original.lastScanAt) == original
        internal fun apply(movie: MovieEntity, details: LocalMediaMetadata?, show: LocalMediaMetadata?, season: LocalMediaMetadata?,
            metadataComplete: Boolean = true, invalidSidecar: Boolean = false): MovieEntity {
            if (movie.isLocked) return movie
            // Confirmed corruption in any applicable sidecar wins over a separate transport failure.
            // Preserve display metadata, but never retain a stale permissive rating or inherit one.
            if (invalidSidecar) return withUnknownLocalRating(movie)
            if (!metadataComplete) return movie
            if (details == null && show == null && season == null) return clearOverrides(movie)
            val episode = details?.kind == "episodedetails" || movie.episodeInfo != null
            val rating = if (details?.certificationSpecified == true) details else show
            val merged = LocalMediaMetadata(if (episode) "episodedetails" else "movie", title = details?.title,
                plot = details?.plot ?: show?.plot, tagline = details?.tagline, year = details?.year ?: show?.year,
                genres = details?.genres?.takeIf { it.isNotEmpty() } ?: show?.genres.orEmpty(), runtime = details?.runtime,
                certification = rating?.certification,
                certificationSpecified = rating?.certificationSpecified == true,
                tmdbId = if (episode) show?.tmdbId else details?.tmdbId,
                showTitle = if (episode) details?.showTitle ?: show?.title else null,
                season = if (episode) details?.season ?: season?.season else null,
                episode = if (episode) details?.episode else null, collection = details?.collection, edition = details?.edition)
            val encoded = json.encodeToString(LocalMediaMetadata.serializer(), merged)
            val base = if (encoded != movie.localMetadataJson) clearOverrides(movie) else movie
            return applyFields(base, merged).copy(localMetadataJson = encoded, hasLocalMetadata = true)
        }
        private fun withUnknownLocalRating(movie: MovieEntity): MovieEntity {
            val previous = movie.localMetadataJson?.let { runCatching { json.decodeFromString(LocalMediaMetadata.serializer(), it) }.getOrNull() }
                ?: LocalMediaMetadata(if (movie.episodeInfo != null) "episodedetails" else "movie")
            val blocked = previous.copy(certification = null, certificationSpecified = true)
            return movie.copy(ageCertification = null, certificationFetched = true, hasLocalMetadata = true,
                localMetadataJson = json.encodeToString(LocalMediaMetadata.serializer(), blocked))
        }
        internal fun reapply(movie: MovieEntity): MovieEntity {
            if (movie.isLocked) return movie
            val details = movie.localMetadataJson?.let { runCatching { json.decodeFromString(LocalMediaMetadata.serializer(), it) }.getOrNull() } ?: return movie
            return applyFields(movie, details)
        }
        private fun applyFields(movie: MovieEntity, details: LocalMediaMetadata): MovieEntity {
            val episode = details.kind == "episodedetails"
            val title = details.title ?: movie.title
            return movie.copy(title = title, sortTitle = WatchRules.sortTitle(title), year = details.year ?: movie.year,
                overview = details.plot ?: movie.overview, tagline = details.tagline ?: movie.tagline,
                genres = details.genres.takeIf { it.isNotEmpty() } ?: movie.genres, runtimeMinutes = details.runtime ?: movie.runtimeMinutes,
                ageCertification = if (details.certificationSpecified) details.certification else movie.ageCertification,
                certificationFetched = details.certificationSpecified || movie.certificationFetched,
                tmdbId = if (episode) null else details.tmdbId ?: movie.tmdbId,
                seriesTmdbId = if (episode) details.tmdbId ?: movie.seriesTmdbId else movie.seriesTmdbId,
                seriesTitle = if (episode) details.showTitle ?: movie.episodeInfo?.seriesTitle else movie.seriesTitle,
                seasonNumber = if (episode) details.season ?: movie.episodeInfo?.season else movie.seasonNumber,
                episodeNumber = if (episode) details.episode ?: movie.episodeInfo?.episode else movie.episodeNumber,
                edition = details.edition ?: movie.edition, franchiseName = details.collection ?: movie.franchiseName,
                franchiseId = if (details.collection != null) null else movie.franchiseId)
        }
        private fun clearOverrides(movie: MovieEntity): MovieEntity {
            val old = movie.localMetadataJson?.let { runCatching { json.decodeFromString(LocalMediaMetadata.serializer(), it) }.getOrNull() } ?: return movie
            val localEpisode = com.dineshdevkota.cinevault.core.EpisodeParser.parse(movie.filePath)
            val title = if (old.title != null) movie.parsedTitle else movie.title
            return movie.copy(title = title, sortTitle = WatchRules.sortTitle(title), year = if (old.year != null) movie.parsedYear else movie.year,
                overview = if (old.plot != null) null else movie.overview, tagline = if (old.tagline != null) null else movie.tagline,
                genres = if (old.genres.isNotEmpty()) emptyList() else movie.genres, runtimeMinutes = if (old.runtime != null) null else movie.runtimeMinutes,
                ageCertification = if (old.certificationSpecified) null else movie.ageCertification,
                certificationFetched = if (old.certificationSpecified) false else movie.certificationFetched,
                tmdbId = if (old.kind == "movie" && old.tmdbId != null) null else movie.tmdbId,
                seriesTmdbId = if (old.kind == "episodedetails" && old.tmdbId != null) null else movie.seriesTmdbId,
                seriesTitle = if (old.showTitle != null) localEpisode?.seriesTitle else movie.seriesTitle,
                seasonNumber = if (old.season != null) localEpisode?.season else movie.seasonNumber,
                episodeNumber = if (old.episode != null) localEpisode?.episode else movie.episodeNumber,
                edition = if (old.edition != null) null else movie.edition, franchiseName = if (old.collection != null) null else movie.franchiseName,
                metadataFetched = false, hasLocalMetadata = false, localMetadataJson = null)
        }
    }
}
