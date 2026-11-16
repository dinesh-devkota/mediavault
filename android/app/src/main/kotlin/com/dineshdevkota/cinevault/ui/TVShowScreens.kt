@file:OptIn(ExperimentalTvMaterial3Api::class)

package com.dineshdevkota.cinevault.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Card
import androidx.tv.material3.CardDefaults
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import com.dineshdevkota.cinevault.core.Tmdb
import com.dineshdevkota.cinevault.data.MovieEntity

@Composable
internal fun CollectionRow(
    title: String, movies: List<MovieEntity>, onOpen: (MovieEntity) -> Unit, onShow: (String) -> Unit,
) {
    val collection = remember(movies) { collectionItems(movies, limit = 20) }
    Column {
        Text(title, style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(horizontal = ScreenPadding))
        LazyRow(contentPadding = PaddingValues(horizontal = ScreenPadding, vertical = 16.dp), horizontalArrangement = Arrangement.spacedBy(24.dp)) {
            items(collection, key = { it.id }) { item ->
                when (item) {
                    is CollectionItem.Movie -> PosterCard(item.movie, onClick = { onOpen(item.movie) }, modifier = Modifier.width(PosterWidth))
                    is CollectionItem.Show -> TVArtworkCard(item.show.title, "${item.show.seasons.size} seasons", item.show.posterPath,
                        modifier = Modifier.width(PosterWidth), onClick = { onShow(item.show.id) })
                }
            }
        }
    }
}

@Composable
internal fun TVShowRow(episodes: List<MovieEntity>, onShow: (String) -> Unit) {
    val shows = remember(episodes) { groupTVShows(episodes).take(20) }
    Column {
        Text("TV Shows", style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(horizontal = ScreenPadding))
        LazyRow(contentPadding = PaddingValues(horizontal = ScreenPadding, vertical = 16.dp), horizontalArrangement = Arrangement.spacedBy(24.dp)) {
            items(shows, key = { it.id }) { show ->
                TVArtworkCard(show.title, "${show.seasons.size} seasons", show.posterPath,
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
) {
    val shows = preparedShows ?: remember(episodes) { groupTVShows(episodes) }
    var showId by rememberSaveable(initialShowId) { mutableStateOf(initialShowId) }
    var season by rememberSaveable(initialShowId) { mutableStateOf<Int?>(null) }
    var anchorId by rememberSaveable(initialShowId) { mutableStateOf(shows.firstOrNull { it.id == initialShowId }?.episodes?.firstOrNull()?.id) }
    var lastSeason by rememberSaveable(initialShowId) { mutableStateOf<Int?>(null) }
    var lastEpisode by rememberSaveable(initialShowId) { mutableStateOf<String?>(null) }
    val transitionFocus = remember { FocusRequester() }
    var holdingFocus by remember { mutableStateOf(false) }
    var focusRequest by remember { mutableIntStateOf(0) }
    fun holdFocus() { if (restoreNavigationFocus) { focusRequest++; holdingFocus = true; transitionFocus.requestFocus() } }
    val show = shows.firstOrNull { it.id == showId }
        ?: shows.firstOrNull { candidate -> anchorId != null && candidate.episodes.any { it.id == anchorId } }
    val goBack: () -> Unit = {
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
        LazyVerticalGrid(
            modifier = Modifier.weight(1f), state = grid,
            columns = GridCells.Adaptive(if (season == null) 148.dp else 260.dp),
            contentPadding = PaddingValues(start = ScreenPadding, end = ScreenPadding, top = 8.dp, bottom = 48.dp),
            horizontalArrangement = Arrangement.spacedBy(28.dp), verticalArrangement = Arrangement.spacedBy(28.dp),
        ) {
            if (show == null) {
                items(shows, key = { it.id }) { item ->
                    TVArtworkCard(item.title, "${item.seasons.size} seasons", item.posterPath,
                        cardModifier = focusModifier(item.id == targetKey, "tv-show:${item.id}"),
                        onClick = { holdFocus(); showId = item.id; anchorId = item.episodes.firstOrNull()?.id; season = null })
                }
            } else if (season == null) {
                items(show.seasons, key = { it }) { number ->
                    val children = show.episodes.filter { tvSeason(it) == number }
                    TVArtworkCard(tvSeasonTitle(number), "${children.size} episodes", children.firstNotNullOfOrNull { it.seasonPosterPath },
                        cardModifier = focusModifier(number == targetSeason, "tv-season:${show.id}:$number"),
                        onClick = { holdFocus(); lastSeason = number; season = number })
                }
            } else {
                items(children, key = { it.id }) { episode ->
                    val number = tvEpisode(episode).takeUnless { it == Int.MAX_VALUE }
                    TVArtworkCard(number?.let { "E$it · ${episode.title}" } ?: episode.title,
                        if (episode.isWatched) "Watched" else if (episode.isInProgress) "In progress" else "Episode",
                        episode.backdropPath, wide = true,
                        cardModifier = focusModifier(episode.id == targetEpisode, "tv-episode:${episode.id}"),
                        onClick = { lastEpisode = episode.id; onOpen(episode) })
                }
            }
        }
    }
}

@Composable
internal fun TVArtworkCard(
    title: String, subtitle: String, path: String?, modifier: Modifier = Modifier,
    wide: Boolean = false, cardModifier: Modifier = Modifier, onClick: () -> Unit,
) {
    Column(modifier) {
        Card(onClick = onClick,
            modifier = cardModifier.fillMaxWidth().aspectRatio(if (wide) 16f / 9f else 2f / 3f).pointerClick(onClick = onClick),
            shape = CardDefaults.shape(RoundedCornerShape(10.dp))) {
            Artwork(Tmdb.imageUrl(path, if (wide) "w780" else "w342"), title, Modifier.fillMaxSize())
        }
        Text(title, style = MaterialTheme.typography.titleSmall, maxLines = 2,
            overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 10.dp).clearAndSetSemantics {})
        Text(subtitle, style = MaterialTheme.typography.labelMedium, color = SecondaryText)
    }
}
