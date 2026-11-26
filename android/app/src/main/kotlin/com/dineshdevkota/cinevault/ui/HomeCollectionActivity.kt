package com.dineshdevkota.cinevault.ui

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.tv.material3.Text
import com.dineshdevkota.cinevault.container

/** A temporary browse destination leaves Home's scroll, remote focus and Library preferences intact. */
class HomeCollectionActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val collection = intent.getStringExtra("collection")?.let { name -> HomeCollection.entries.firstOrNull { it.name == name } }
            ?: return finish()
        setCineVaultContent { HomeCollectionScreen(collection) }
    }

    companion object {
        internal fun start(context: Context, collection: HomeCollection) = context.startActivity(
            Intent(context, HomeCollectionActivity::class.java).putExtra("collection", collection.name))
    }
}

@Composable
private fun HomeCollectionScreen(collection: HomeCollection) {
    val context = LocalContext.current
    val container = context.container
    val movies by remember { container.library.observeAll() }.collectAsStateWithLifecycle(initialValue = null)
    val sources by remember { container.library.observeSources() }.collectAsStateWithLifecycle(initialValue = null)
    val ready = movies != null && sources != null
    val items = remember(collection, movies, sources) { homeCollectionItems(collection, movies.orEmpty(), sources.orEmpty()) }
    val continuing = remember(collection, movies, sources) {
        if (collection == HomeCollection.CONTINUE) continueWatchingItems(movies.orEmpty(), sources.orEmpty(), limit = Int.MAX_VALUE) else emptyList()
    }
    val shows = remember(items) { items.filterIsInstance<CollectionItem.Show>().map { it.show } }
    var selectedShow by rememberSaveable { mutableStateOf<String?>(null) }
    var originId by rememberSaveable { mutableStateOf<String?>(null) }
    var originEpisode by rememberSaveable { mutableStateOf<String?>(null) }
    val grid = rememberLazyGridState()
    val transitionFocus = remember { FocusRequester() }
    val resultFocus = remember { FocusRequester() }
    val backFocus = remember { FocusRequester() }
    var holdingFocus by remember { mutableStateOf(false) }
    var restore by remember { mutableStateOf(false) }
    val windowFocused = LocalWindowInfo.current.isWindowFocused
    val returnId = continuing.firstOrNull { it.id == originId }?.id ?: items.firstOrNull { it.id == originId }?.id ?: items.firstOrNull { item ->
        item is CollectionItem.Show && item.show.episodes.any { it.id == originEpisode }
    }?.id
    var resultReady by remember(selectedShow, returnId) { mutableStateOf(false) }
    var backReady by remember(selectedShow) { mutableStateOf(false) }
    fun holdFocus() { holdingFocus = true; transitionFocus.requestFocus() }
    fun closeShow() { holdFocus(); selectedShow = null; restore = true }

    LaunchedEffect(windowFocused, returnId) {
        if (windowFocused && originId != null && selectedShow == null) restore = true
    }

    LaunchedEffect(ready, shows, selectedShow) {
        if (ready && selectedShow != null && shows.none { it.id == selectedShow || it.episodes.any { episode -> episode.id == originEpisode } }) {
            closeShow()
        }
    }
    LaunchedEffect(restore, selectedShow, returnId, items) {
        if (restore && selectedShow == null && returnId != null && grid.layoutInfo.visibleItemsInfo.none { it.key == returnId }) {
            val index = if (collection == HomeCollection.CONTINUE) continuing.indexOfFirst { it.id == returnId }
                else items.indexOfFirst { it.id == returnId }
            if (index >= 0) grid.scrollToItem(index)
        }
    }
    LaunchedEffect(restore, selectedShow, resultReady, backReady, windowFocused) {
        if (restore && selectedShow == null && windowFocused) {
            val restored = if (returnId != null && resultReady) resultFocus.requestFocus()
                else if (returnId == null && backReady) backFocus.requestFocus() else false
            if (restored) { restore = false; holdingFocus = false }
        }
    }

    Box(Modifier.fillMaxSize().focusRequester(transitionFocus).focusProperties { canFocus = holdingFocus }.focusable()) {
        if (selectedShow != null) {
            TVShowBrowser(emptyList(), { MovieDetailActivity.start(context, it.id) }, initialShowId = selectedShow,
                preparedShows = shows, onExit = ::closeShow, restoreNavigationFocus = true,
                onNavigationFocusReady = { holdingFocus = false })
        } else {
            Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(Modifier.fillMaxWidth().padding(horizontal = ScreenPadding, vertical = 12.dp),
                    horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    OutlinedButton(onClick = { (context as? ComponentActivity)?.finish() },
                        modifier = Modifier.focusRequester(backFocus).onGloballyPositioned { backReady = true }) { Text("Back") }
                    ScreenHeader(collection.title, Modifier.weight(1f), showBack = false,
                        trailing = if (!ready) null else (if (collection == HomeCollection.CONTINUE) continuing.size else items.size)
                            .let { "$it ${if (it == 1) "title" else "titles"}" })
                }
                if (ready && items.isEmpty() && continuing.isEmpty()) {
                    EmptyState(if (collection == HomeCollection.WATCHLIST) "Your Watchlist is empty" else "Nothing here yet",
                        when (collection) {
                            HomeCollection.WATCHLIST -> "Open a title and choose Add to Watchlist to save it for later."
                            HomeCollection.CONTINUE -> "Start a movie or show and return here to pick up where you left off."
                            HomeCollection.UNWATCHED -> "You're all caught up. New titles will appear after your next scan."
                            else -> "Add a folder with ${collection.title.lowercase()} in Sources, then scan it."
                        })
                } else if (ready) {
                    LazyVerticalGrid(GridCells.Adaptive(if (collection == HomeCollection.CONTINUE) 260.dp else 148.dp),
                        Modifier.weight(1f).testTag("home-collection-grid"), state = grid,
                        contentPadding = PaddingValues(start = ScreenPadding, end = ScreenPadding, top = 8.dp, bottom = 48.dp),
                        horizontalArrangement = Arrangement.spacedBy(28.dp), verticalArrangement = Arrangement.spacedBy(28.dp)) {
                        if (collection == HomeCollection.CONTINUE) items(continuing, key = { it.id }) { item ->
                            TVArtworkCard(item.title, item.label, item.movie.backdropPath ?: item.movie.posterPath, wide = true,
                                cardModifier = Modifier.testTag("collection-continue:${item.id}").then(if (item.id == returnId)
                                    Modifier.focusRequester(resultFocus).onGloballyPositioned { resultReady = true } else Modifier),
                                onClick = { originId = item.id; originEpisode = null; MovieDetailActivity.start(context, item.movie.id) })
                        } else items(items, key = { it.id }) { item ->
                            val modifier = Modifier.testTag("collection-item:${item.id}").then(if (item.id == returnId)
                                Modifier.focusRequester(resultFocus).onGloballyPositioned { resultReady = true } else Modifier)
                            when (item) {
                                is CollectionItem.Movie -> PosterCard(item.movie, cardModifier = modifier,
                                    onClick = { originId = item.id; originEpisode = null; MovieDetailActivity.start(context, item.movie.id) })
                                is CollectionItem.Show -> TVArtworkCard(item.show.title,
                                    "${item.show.seasons.size} ${if (item.show.seasons.size == 1) "season" else "seasons"}", item.show.posterPath,
                                    cardModifier = modifier, onClick = {
                                        originId = item.id; originEpisode = item.show.episodes.firstOrNull()?.id
                                        holdFocus(); selectedShow = item.show.id
                                    })
                            }
                        }
                    }
                }
            }
        }
    }
}
