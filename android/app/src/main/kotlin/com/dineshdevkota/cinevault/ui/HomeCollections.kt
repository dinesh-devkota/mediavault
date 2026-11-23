package com.dineshdevkota.cinevault.ui

import com.dineshdevkota.cinevault.core.LibraryQuery
import com.dineshdevkota.cinevault.core.MediaKind
import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.data.SourceEntity

internal enum class HomeCollection(val title: String, val kind: MediaKind? = null) {
    CONTINUE("Continue Watching"), WATCHLIST("Watchlist"), UNWATCHED("Unwatched"),
    MOVIES("Movies", MediaKind.MOVIE), DOCUMENTARIES("Documentaries", MediaKind.DOCUMENTARY),
    TV_SHOWS("TV Shows", MediaKind.TV_SHOW), MUSIC("Music", MediaKind.MUSIC);

    companion object {
        fun forKind(kind: MediaKind): HomeCollection? = entries.firstOrNull { it.kind == kind }
    }
}

/** Home and See all share the same source rules; no saved Library filter participates. */
internal fun homeAvailableItems(items: List<MovieEntity>, sources: List<SourceEntity>): List<MovieEntity> =
    searchableItems(items, sources).filterNot { it.isPhoto }.sortedByDescending { it.addedAt }

internal fun homeCollectionItems(collection: HomeCollection, items: List<MovieEntity>, sources: List<SourceEntity>): List<CollectionItem> {
    val available = homeAvailableItems(items, sources)
    val matching = when (collection) {
        HomeCollection.WATCHLIST -> LibraryQuery.watchlist(available)
        HomeCollection.UNWATCHED -> available.filterNot { it.isWatched }
        HomeCollection.CONTINUE -> return emptyList() // Continue Watching preserves its exact episode/resume targets.
        else -> available.filter { it.mediaKind == collection.kind }
    }
    return collectionItems(matching)
}
