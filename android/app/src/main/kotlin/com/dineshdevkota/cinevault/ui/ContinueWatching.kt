package com.dineshdevkota.cinevault.ui

import com.dineshdevkota.cinevault.core.MediaFile
import com.dineshdevkota.cinevault.core.MediaKind
import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.data.SourceEntity
import java.util.Locale

internal enum class ContinueAction(val label: String) {
    RESUME("Resume"), NEXT_EPISODE("Next episode"), NEXT_AVAILABLE("Next available")
}

internal data class ContinueWatchingItem(
    val id: String,
    val title: String,
    val movie: MovieEntity,
    val action: ContinueAction,
    val activityAt: Long?,
) {
    val label: String get() = movie.episodeInfo?.let {
        "${action.label} · ${String.format(Locale.ROOT, "S%02dE%02d", it.season, it.episode)}"
    } ?: action.label
}

// Stable file order for equal timestamps and alternate encodes with no playback history.
private val fileOrder = compareBy<MovieEntity> { it.filePath.lowercase(Locale.ROOT) }.thenBy { it.sourceId }.thenBy { it.id }
private val byRecentPlayback = compareByDescending<MovieEntity> { it.lastPlayedAt }.then(fileOrder)

private fun MovieEntity.hasWatchActivity() = isInProgress || (isWatched && lastPlayedAt != null)

private fun playableEntries(items: List<MovieEntity>, sources: List<SourceEntity>): List<MovieEntity> =
    searchableItems(items, sources).filter { MediaFile.isPlayable(it.filePath) }

internal fun continueWatchingItems(items: List<MovieEntity>, sources: List<SourceEntity>, limit: Int = 20): List<ContinueWatchingItem> {
    if (limit <= 0) return emptyList()
    if (items.none { it.hasWatchActivity() }) return emptyList()
    val (episodes, otherMedia) = playableEntries(items, sources).partition { it.mediaKind == MediaKind.TV_SHOW }
    val choices = otherMedia.filter { it.isInProgress && it.mediaKind != MediaKind.MUSIC }.mapTo(mutableListOf()) {
        ContinueWatchingItem("movie:${it.id}", it.title, it, ContinueAction.RESUME, it.lastPlayedAt)
    }
    if (episodes.any { it.hasWatchActivity() }) {
        for (show in groupTVShows(episodes)) {
            val anchor = show.episodes.filter { it.hasWatchActivity() }.minWithOrNull(byRecentPlayback) ?: continue
            if (anchor.isInProgress) {
                choices += ContinueWatchingItem("show:${show.id}", show.title, anchor, ContinueAction.RESUME, anchor.lastPlayedAt)
            } else {
                show.nextAfter(anchor)?.let(choices::add)
            }
        }
    }
    return choices.sortedWith(compareByDescending<ContinueWatchingItem> { it.activityAt }.thenBy { it.id }).take(limit)
}

internal fun nextEpisodeFor(current: MovieEntity, items: List<MovieEntity>, sources: List<SourceEntity>): ContinueWatchingItem? {
    if (current.episodeInfo == null) return null
    val episodes = playableEntries(items, sources).filter { it.mediaKind == MediaKind.TV_SHOW }
    val show = groupTVShows(episodes).firstOrNull { group -> group.episodes.any { it.id == current.id } } ?: return null
    return show.nextAfter(current)
}

private fun TVShowGroup.nextAfter(anchor: MovieEntity): ContinueWatchingItem? {
    val from = anchor.episodeInfo ?: return null
    val later = episodes.mapNotNull { movie ->
        val info = movie.episodeInfo ?: return@mapNotNull null
        val sameSequence = (info.season == 0) == (from.season == 0)
        val after = info.season > from.season || (info.season == from.season && info.episode > from.episode)
        if (sameSequence && after) (info.season to info.episode) to movie else null
    }.groupBy({ it.first }, { it.second })
    val slot = later.entries.filter { (_, copies) -> copies.none { it.isWatched } }
        .minWithOrNull(compareBy({ it.key.first }, { it.key.second })) ?: return null
    val (season, episode) = slot.key
    val consecutive = (season == from.season && episode == from.episode + 1) ||
        (season == from.season + 1 && episode == 1)
    val action = if (consecutive) ContinueAction.NEXT_EPISODE else ContinueAction.NEXT_AVAILABLE
    val target = slot.value.filter { it.isInProgress }.minWithOrNull(byRecentPlayback) ?: slot.value.minWith(fileOrder)
    return ContinueWatchingItem("show:$id", title, target, action, anchor.lastPlayedAt)
}
