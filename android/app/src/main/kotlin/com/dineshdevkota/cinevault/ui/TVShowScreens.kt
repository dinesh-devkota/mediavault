@file:OptIn(ExperimentalTvMaterial3Api::class)

package com.dineshdevkota.cinevault.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Card
import androidx.tv.material3.CardDefaults
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import com.dineshdevkota.cinevault.core.Tmdb
import com.dineshdevkota.cinevault.core.MediaKind
import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.container
import com.dineshdevkota.cinevault.library.watchStatusItems
import androidx.lifecycle.compose.collectAsStateWithLifecycle

@Composable
internal fun CollectionRow(
    title: String, movies: List<MovieEntity>, onOpen: (MovieEntity) -> Unit, onSeeAll: (() -> Unit)? = null, onShow: (String) -> Unit,
) {
    val collection = remember(movies) { collectionItems(movies, limit = 20) }
    Column {
        HomeShelfHeader(title, onSeeAll)
        LazyRow(contentPadding = PaddingValues(horizontal = ScreenPadding, vertical = 16.dp), horizontalArrangement = Arrangement.spacedBy(24.dp)) {
            items(collection, key = { it.id }) { item ->
                when (item) {
                    is CollectionItem.Movie -> PosterCard(item.movie, onClick = { onOpen(item.movie) }, modifier = Modifier.width(PosterWidth))
                    is CollectionItem.Show -> TVArtworkCard(item.show.title, "${item.show.seasons.size} seasons", item.show.posterPath, artworkMovie = item.show.episodes.firstOrNull(),
                        modifier = Modifier.width(PosterWidth), onClick = { onShow(item.show.id) })
                }
            }
        }
    }
}

@Composable
internal fun TVShowRow(episodes: List<MovieEntity>, onSeeAll: (() -> Unit)? = null, onShow: (String) -> Unit) {
    val shows = remember(episodes) { groupTVShows(episodes).take(20) }
    Column {
        HomeShelfHeader("TV Shows", onSeeAll)
        LazyRow(contentPadding = PaddingValues(horizontal = ScreenPadding, vertical = 16.dp), horizontalArrangement = Arrangement.spacedBy(24.dp)) {
            items(shows, key = { it.id }) { show ->
                TVArtworkCard(show.title, "${show.seasons.size} seasons", show.posterPath, artworkMovie = show.episodes.firstOrNull(),
                    modifier = Modifier.width(PosterWidth), onClick = { onShow(show.id) })
            }
        }
    }
}

@Composable
internal fun TVShowBrowser(
    episodes: List<MovieEntity>, onOpen: (MovieEntity) -> Unit,
    initialShowId: String? = null, onExit: (() -> Unit)? = null,
    preparedShows: List<TVShowGroup>? = null,
    restoreNavigationFocus: Boolean = false,
    onNavigationFocusReady: () -> Unit = {},
    emptyContent: (@Composable () -> Unit)? = null,
) {
    val shows = preparedShows ?: remember(episodes) { groupTVShows(episodes) }
    var showId by rememberSaveable(initialShowId) { mutableStateOf(initialShowId) }
    var season by rememberSaveable(initialShowId) { mutableStateOf<Int?>(null) }
    var anchorId by rememberSaveable(initialShowId) { mutableStateOf(shows.firstOrNull { it.id == initialShowId }?.episodes?.firstOrNull()?.id) }
    var lastSeason by rememberSaveable(initialShowId) { mutableStateOf<Int?>(null) }
    var lastEpisode by rememberSaveable(initialShowId) { mutableStateOf<String?>(null) }
    val transitionFocus = remember { FocusRequester() }
    val navigationFocus = remember { FocusRequester() }
    var holdingFocus by remember { mutableStateOf(false) }
    var focusRequest by remember { mutableIntStateOf(0) }
    fun holdFocus() {
        navigationFocus.requestFocus()
        if (restoreNavigationFocus) { focusRequest++; holdingFocus = true; transitionFocus.requestFocus() }
    }
    val show = shows.firstOrNull { it.id == showId }
        ?: shows.firstOrNull { candidate -> anchorId != null && candidate.episodes.any { it.id == anchorId } }
    val selection = remember { WatchSelection() }
    val container = LocalContext.current.container
    val sources by remember { container.library.observeSources() }.collectAsStateWithLifecycle(initialValue = emptyList())
    val allMovies by remember { container.library.observeAll() }.collectAsStateWithLifecycle(initialValue = emptyList())
    val goBack: () -> Unit = {
        selection.finish()
        if (season != null) { holdFocus(); season = null }
        else if (initialShowId != null && onExit != null) onExit()
        else { showId = null; anchorId = null }
    }
    BackHandler(enabled = showId != null || onExit != null) {
        if (showId == null) onExit?.invoke() else goBack()
    }
    val requestedShow = showId
    val requestedSeason = season
    val resolvedId = show?.id
    val availableSeasons = show?.seasons.orEmpty()
    LaunchedEffect(requestedShow, resolvedId, requestedSeason, availableSeasons) {
        if (showId != requestedShow || season != requestedSeason) return@LaunchedEffect
        if (requestedShow != null && resolvedId == null && restoreNavigationFocus && onExit != null) {
            onExit()
        } else {
            if (requestedShow != resolvedId) showId = resolvedId
            if (resolvedId == null) anchorId = null
            if (requestedSeason != null && requestedSeason !in availableSeasons) season = null
        }
    }
    val children = remember(show, season) { show?.episodes.orEmpty().filter { tvSeason(it) == season }
        .sortedWith(compareBy(::tvEpisode).thenBy { it.filePath }) }
    val scopeItems = if (show == null) shows.flatMap { it.episodes } else if (season == null) show.episodes else children
    val selectable = remember(scopeItems, sources) { watchStatusItems(scopeItems, sources) }
    val selectableIds = remember(selectable) { selectable.map { it.id }.toSet() }
    val completeShow = remember(allMovies, sources, show?.id, anchorId) {
        val allEpisodes = watchStatusItems(allMovies, sources).filter { !it.isHidden && it.mediaKind == MediaKind.TV_SHOW }
        groupTVShows(allEpisodes).firstOrNull { it.id == show?.id || (anchorId != null && it.episodes.any { episode -> episode.id == anchorId }) }
    }
    val wholeScopeItems = completeShow?.episodes.orEmpty().filter { season == null || tvSeason(it) == season }
    val scopeTitle = show?.let { selected -> season?.let { "${selected.title} · ${tvSeasonTitle(it)}" } ?: selected.title } ?: "TV Shows"
    fun selectionFor(items: List<MovieEntity>): Boolean? {
        val ids = items.map { it.id }.filter { it in selectableIds }
        return if (selection.selecting && ids.isNotEmpty()) selection.ids.containsAll(ids) else null
    }
    val showGrid = rememberLazyGridState()
    val seasonGrid = rememberLazyGridState()
    val episodeGrid = rememberLazyGridState()
    val grid = if (show == null) showGrid else if (season == null) seasonGrid else episodeGrid
    val targetSeason = lastSeason?.takeIf { it in show?.seasons.orEmpty() } ?: show?.seasons?.firstOrNull()
    val targetEpisode = lastEpisode?.takeIf { id -> children.any { it.id == id } } ?: children.firstOrNull()?.id
    val targetKey = if (show == null) shows.firstOrNull()?.id else if (season == null) targetSeason else targetEpisode
    val targetIndex = if (show == null) 0 else if (season == null) show.seasons.indexOfFirst { it == targetSeason } else children.indexOfFirst { it.id == targetEpisode }
    val targetFocus = remember { FocusRequester() }
    var placed by remember(show?.id, season, targetKey) { mutableStateOf(false) }
    var focusPending by remember(show?.id, season) { mutableStateOf(restoreNavigationFocus) }
    val windowFocused = LocalWindowInfo.current.isWindowFocused
    val request = focusRequest
    val requestedEpisode = lastEpisode
    val requestedPending = focusPending
    val requestedPlaced = placed
    fun requestIsCurrent() = focusRequest == request && showId == requestedShow && season == requestedSeason && lastEpisode == requestedEpisode
    LaunchedEffect(windowFocused) { if (restoreNavigationFocus && windowFocused) { focusRequest++; focusPending = true } }
    LaunchedEffect(show?.id, requestedSeason, targetKey, requestedPending, request) {
        if (restoreNavigationFocus && requestedPending && requestIsCurrent() && targetIndex >= 0 && grid.layoutInfo.visibleItemsInfo.none { it.key == targetKey }) {
            grid.scrollToItem(targetIndex)
        }
    }
    LaunchedEffect(requestedPlaced, requestedPending, windowFocused, request) {
        if (restoreNavigationFocus && requestedPlaced && requestedPending && windowFocused && requestIsCurrent() && targetFocus.requestFocus()) {
            focusPending = false
            holdingFocus = false
            onNavigationFocusReady()
        }
    }
    fun focusModifier(target: Boolean, tag: String): Modifier = Modifier.testTag(tag).then(
        if (restoreNavigationFocus && target) Modifier.focusRequester(targetFocus).onGloballyPositioned { placed = true } else Modifier)
    Column(Modifier.fillMaxSize().focusRequester(transitionFocus).focusProperties { canFocus = holdingFocus }.focusable(),
        verticalArrangement = Arrangement.spacedBy(16.dp)) {
        if (showId != null || onExit != null) {
            Row(Modifier.padding(horizontal = ScreenPadding), horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                OutlinedButton(onClick = { if (showId == null) onExit?.invoke() else goBack() }) { Text("Back") }
                Text(show?.let { selected -> season?.let { "${selected.title} · ${tvSeasonTitle(it)}" } ?: selected.title } ?: "TV Shows",
                    style = MaterialTheme.typography.titleLarge)
            }
        }
        BulkWatchControls(selectable, "$scopeTitle · Current results", selection,
            Modifier.padding(horizontal = ScreenPadding), allowWholeScope = show != null,
            wholeScopeItems = wholeScopeItems, wholeScopeTitle = "$scopeTitle · All available episodes",
            navigationFocus = navigationFocus)
        LazyVerticalGrid(
            modifier = Modifier.weight(1f), state = grid,
            columns = GridCells.Adaptive(if (season == null) 148.dp else 260.dp),
            contentPadding = PaddingValues(start = ScreenPadding, end = ScreenPadding, top = 8.dp, bottom = 48.dp),
            horizontalArrangement = Arrangement.spacedBy(28.dp), verticalArrangement = Arrangement.spacedBy(28.dp),
        ) {
            if (show == null) {
                if (shows.isEmpty()) item(span = { GridItemSpan(maxLineSpan) }) {
                    if (emptyContent != null) emptyContent()
                    else EmptyState("No matching TV shows", "Try another filter or check your sources.")
                }
                items(shows, key = { it.id }) { item ->
                    TVArtworkCard(item.title, "${item.seasons.size} seasons", item.posterPath, artworkMovie = item.episodes.firstOrNull(),
                        selected = selectionFor(item.episodes),
                        cardModifier = focusModifier(item.id == targetKey, "tv-show:${item.id}"),
                        onClick = {
                            if (selection.selecting) selection.toggle(item.episodes.map { it.id }.filter { it in selectableIds })
                            else { holdFocus(); showId = item.id; anchorId = item.episodes.firstOrNull()?.id; season = null }
                        })
                }
            } else if (season == null) {
                items(show.seasons, key = { it }) { number ->
                    val children = show.episodes.filter { tvSeason(it) == number }
                    TVArtworkCard(tvSeasonTitle(number), "${children.size} episodes", children.firstNotNullOfOrNull { it.seasonPosterPath },
                        artworkMovie = children.firstOrNull(), seasonArtwork = true,
                        selected = selectionFor(children),
                        cardModifier = focusModifier(number == targetSeason, "tv-season:${show.id}:$number"),
                        onClick = {
                            if (selection.selecting) selection.toggle(children.map { it.id }.filter { it in selectableIds })
                            else { holdFocus(); lastSeason = number; season = number }
                        })
                }
            } else {
                items(children, key = { it.id }) { episode ->
                    val number = tvEpisode(episode).takeUnless { it == Int.MAX_VALUE }
                    TVArtworkCard(number?.let { "E$it · ${episode.title}" } ?: episode.title,
                        if (episode.isWatched) "Watched" else if (episode.isInProgress) "In progress" else "Episode",
                        episode.backdropPath, wide = true, artworkMovie = episode,
                        selected = selectionFor(listOf(episode)),
                        cardModifier = focusModifier(episode.id == targetEpisode, "tv-episode:${episode.id}"),
                        onClick = {
                            if (selection.selecting) selection.toggle(listOf(episode.id).filter { it in selectableIds })
                            else { lastEpisode = episode.id; onOpen(episode) }
                        })
                }
            }
        }
    }
}

@Composable
internal fun TVArtworkCard(
    title: String, subtitle: String, path: String?, modifier: Modifier = Modifier,
    wide: Boolean = false, cardModifier: Modifier = Modifier, selected: Boolean? = null,
    artworkMovie: MovieEntity? = null, seasonArtwork: Boolean = false, onClick: () -> Unit,
) {
    Column(modifier) {
        Card(onClick = onClick,
            modifier = cardModifier.fillMaxWidth().aspectRatio(if (wide) 16f / 9f else 2f / 3f).pointerClick(onClick = onClick)
                .then(if (selected == null) Modifier else Modifier.semantics { this.selected = selected }),
            shape = CardDefaults.shape(RoundedCornerShape(10.dp))) {
            Box(Modifier.fillMaxSize()) {
                val tmdb = Tmdb.imageUrl(path, if (wide) "w780" else "w342")
                if (artworkMovie != null) MediaArtwork(artworkMovie, tmdb, title, Modifier.fillMaxSize(), width = 780,
                    kind = if (wide) com.dineshdevkota.cinevault.jellyfin.JellyfinImage.Backdrop else com.dineshdevkota.cinevault.jellyfin.JellyfinImage.Primary, seasonArtwork = seasonArtwork)
                else Artwork(tmdb, title, Modifier.fillMaxSize())
                selected?.let { SelectionBadge(it, Modifier.align(Alignment.TopStart).padding(8.dp)) }
            }
        }
        Text(title, style = MaterialTheme.typography.titleSmall, maxLines = 2,
            overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 10.dp).clearAndSetSemantics {})
        Text(subtitle, style = MaterialTheme.typography.labelMedium, color = SecondaryText)
    }
}
