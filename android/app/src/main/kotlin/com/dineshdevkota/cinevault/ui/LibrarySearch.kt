package com.dineshdevkota.cinevault.ui

import com.dineshdevkota.cinevault.core.EpisodeParser
import com.dineshdevkota.cinevault.core.LibraryQuery
import com.dineshdevkota.cinevault.core.MediaKind
import com.dineshdevkota.cinevault.core.TitleMatcher
import com.dineshdevkota.cinevault.core.WatchRules
import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.data.SourceEntity
import java.util.Locale

internal sealed interface LibrarySearchResult {
    val id: String
    val title: String
    data class Media(val item: MovieEntity, val logicalId: String? = null) : LibrarySearchResult {
        override val id get() = logicalId ?: "media:${item.id}"
        override val title get() = item.title
    }
    data class Show(val show: TVShowGroup, val matchingEpisodes: Int? = null) : LibrarySearchResult {
        override val id get() = "show:${show.id}"
        override val title get() = show.title
        val subtitle: String get() = matchingEpisodes?.let { "$it matching episodes" }
            ?: show.episodes.distinctBy { tvSeason(it) to tvEpisode(it) }.size.let { count ->
                "${show.seasons.size} ${if (show.seasons.size == 1) "season" else "seasons"} · $count ${if (count == 1) "episode" else "episodes"}"
            }
    }
}

/** Source edits take effect even before a rescan succeeds. */
internal fun searchableItems(items: List<MovieEntity>, sources: List<SourceEntity>): List<MovieEntity> {
    val sourceById = sources.associateBy { it.id }
    return items.filter { item ->
        !item.isHidden && !item.isMissing && sourceById[item.sourceId]?.includesFile(item.filePath) == true
    }
}

/** Rebuild series identities when the library changes, not on each keypress. */
internal class LibrarySearchCatalog(items: List<MovieEntity>) {
    private val titles: List<MovieEntity>
    val shows: List<TVShowGroup>

    init {
        val (episodes, otherMedia) = items.filter { !it.isHidden && !it.isMissing }
            .partition { it.mediaKind == MediaKind.TV_SHOW }
        titles = otherMedia
        shows = groupTVShows(episodes)
    }

    fun results(text: String): List<LibrarySearchResult> = searchLibrary(titles, shows, text)
}

private fun searchLibrary(titles: List<MovieEntity>, shows: List<TVShowGroup>, text: String): List<LibrarySearchResult> {
    val query = text.trim()
    val normalized = TitleMatcher.normalize(query)
    if (normalized.isEmpty()) return emptyList()
    fun matches(value: String): Boolean {
        val candidate = TitleMatcher.normalize(value)
        var start = candidate.indexOf(normalized)
        while (start >= 0) {
            val end = start + normalized.length
            if ((!normalized.first().isDigit() || start == 0 || !candidate[start - 1].isDigit()) &&
                (!normalized.last().isDigit() || end == candidate.length || !candidate[end].isDigit())) return true
            start = candidate.indexOf(normalized, start + 1)
        }
        return false
    }
    val numericQuery = query.all(Char::isDigit)
    val results = titles.filter { item ->
        if (numericQuery) matches(item.title) || matches(item.fileName) || item.genres.any(::matches)
        else LibraryQuery.searchMatches(item, query)
    }.mapTo(mutableListOf<LibrarySearchResult>()) { LibrarySearchResult.Media(it) }
    for (show in shows) {
        fun seriesAliases(episode: MovieEntity): List<Pair<String?, Int?>> {
            val local = EpisodeParser.parse(episode.filePath)
            return listOf(episode.seriesTitle to episode.year,
                episode.episodeInfo?.seriesTitle to episode.episodeInfo?.year, local?.seriesTitle to local?.year)
        }
        val seriesMatch = show.episodes.any { episode ->
            seriesAliases(episode).any { (title, year) -> !title.isNullOrBlank() &&
                (matches(title) || (year != null && normalized.endsWith(" $year") && matches("$title $year"))) }
        } || matches(show.title)
        if (seriesMatch || show.episodes.any { it.genres.any(::matches) }) {
            results += LibrarySearchResult.Show(show)
            continue
        }
        val logicalMatches = show.episodes.filter { episode ->
            val season = tvSeason(episode)
            val number = tvEpisode(episode)
            val codes = listOf("S${season}E$number", "S${season.toString().padStart(2, '0')}E${number.toString().padStart(2, '0')}",
                "${season}x$number", "${season}x${number.toString().padStart(2, '0')}", "Season $season Episode $number")
            matches(episode.title) || matches(episode.fileName) || codes.any(::matches) ||
                seriesAliases(episode).mapNotNull { it.first?.takeIf(String::isNotBlank) }.distinct().any { alias ->
                    matches("$alias ${episode.title}") || matches("$alias ${episode.fileName}") || codes.any { matches("$alias $it") }
                }
        }
            .groupBy { tvSeason(it) to tvEpisode(it) }
        if (logicalMatches.size > 3) results += LibrarySearchResult.Show(show, logicalMatches.size)
        else logicalMatches.values.forEach { copies ->
            // Keep the filename variant the query asks for, without an arbitrary quality preference.
            val representative = copies.sortedWith(compareByDescending<MovieEntity> {
                TitleMatcher.normalize(it.fileName) == normalized
            }.thenBy { it.filePath.lowercase(Locale.ROOT) }.thenBy { it.sourceId }.thenBy { it.id }).first()
            results += LibrarySearchResult.Media(representative,
                "episode:${show.id}:${tvSeason(representative)}:${tvEpisode(representative)}")
        }
    }
    return results.sortedWith(compareBy<LibrarySearchResult> { WatchRules.sortTitle(it.title) }.thenBy { it.id })
}
