package com.dineshdevkota.cinevault.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.focusable
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.tv.material3.Text
import com.dineshdevkota.cinevault.container
import com.dineshdevkota.cinevault.data.MovieEntity
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

@Composable
internal fun SearchTab(movies: List<MovieEntity>?, onOpen: (MovieEntity) -> Unit) {
    val container = LocalContext.current.container
    val sources by remember { container.library.observeSources() }.collectAsStateWithLifecycle(initialValue = null)
    val loadedSources = sources
    if (movies == null || loadedSources == null) {
        ScreenHeader("Search", Modifier.padding(horizontal = ScreenPadding))
        return
    }
    var query by rememberSaveable { mutableStateOf("") }
    var selectedShow by rememberSaveable { mutableStateOf<String?>(null) }
    var originId by rememberSaveable { mutableStateOf<String?>(null) }
    var originEpisode by rememberSaveable { mutableStateOf<String?>(null) }
    val updatedCatalog = remember(movies, loadedSources) { LibrarySearchCatalog(searchableItems(movies, loadedSources)) }
    val latestCatalog by rememberUpdatedState(updatedCatalog)
    var catalog by remember { mutableStateOf(updatedCatalog) }
    var focusedResult by remember { mutableStateOf<String?>(null) }
    val results = remember(catalog, query) { catalog.results(query) }
    val grid = rememberLazyGridState()
    val scope = rememberCoroutineScope()
    val queryFocus = remember { FocusRequester() }
    val resultFocus = remember { FocusRequester() }
    val transitionFocus = remember { FocusRequester() }
    val window = LocalWindowInfo.current
    var holdingFocus by remember { mutableStateOf(false) }
    var holderFocused by remember { mutableStateOf(false) }
    var fieldFocused by remember { mutableStateOf(false) }
    var focusRequest by remember { mutableIntStateOf(0) }
    fun holdFocus() { focusRequest++; holdingFocus = true; transitionFocus.requestFocus() }
    suspend fun parkBeforeRemovingCard() {
        holdFocus()
        val request = focusRequest
        // Enabling a focus target and removing its focused child in the same frame
        // can send focus to the first tab. Keep the old card mounted until the
        // holder itself owns focus, including on the first layout after recreation.
        while (request == focusRequest && holdingFocus && window.isWindowFocused && !holderFocused) {
            withFrameNanos { }
            if (request == focusRequest && holdingFocus && window.isWindowFocused && !holderFocused) {
                transitionFocus.requestFocus()
            }
        }
    }
    var restore by remember { mutableStateOf(false) }
    // Move focus while the old card still exists. Disposing a focused card can otherwise
    // move the remote to the first tab, whose onFocus opens Home before Search can recover.
    LaunchedEffect(Unit) {
        // Serialize Room updates so a second emission cannot cancel a handoff
        // midway and leave focus on the temporary holder.
        snapshotFlow { latestCatalog }.collect { replacement ->
            if (catalog === replacement) return@collect
            val openShow = selectedShow
            if (openShow != null) {
                if (replacement.shows.none { it.id == openShow || it.episodes.any { e -> e.id == originEpisode } }) {
                    parkBeforeRemovingCard()
                    if (selectedShow == openShow) {
                        selectedShow = null
                        restore = true
                    }
                }
            } else {
                val previous = focusedResult?.let { id -> catalog.results(query).firstOrNull { it.id == id } }
                if (previous != null && replacement.results(query).none { it.id == previous.id }) {
                    val oldQuery = query
                    parkBeforeRemovingCard()
                    if (selectedShow == null && query == oldQuery) {
                        originId = previous.id
                        originEpisode = when (previous) {
                            is LibrarySearchResult.Media -> previous.item.id
                            is LibrarySearchResult.Show -> previous.show.episodes.first().id
                        }
                        restore = true
                    }
                }
            }
            catalog = replacement
        }
    }
    var queryReady by remember(selectedShow) { mutableStateOf(false) }
    val returnId = results.firstOrNull { it.id == originId }?.id ?: results.firstOrNull {
        when (it) {
            is LibrarySearchResult.Show -> it.show.episodes.any { episode -> episode.id == originEpisode }
            is LibrarySearchResult.Media -> it.item.id == originEpisode
        }
    }?.id
    var resultReady by remember(selectedShow, returnId) { mutableStateOf(false) }
    val windowFocused = window.isWindowFocused
    val request = focusRequest
    val requestedShow = selectedShow
    val requestedOrigin = originId
    val requestedRestore = restore
    val requestedResultReady = resultReady
    val requestedQueryReady = queryReady
    fun requestIsCurrent() = focusRequest == request && selectedShow == requestedShow && originId == requestedOrigin
    LaunchedEffect(windowFocused) {
        if (windowFocused && requestedOrigin != null && requestedShow == null) { focusRequest++; restore = true }
    }
    LaunchedEffect(requestedRestore, requestedShow, returnId, results, request) {
        if (requestedRestore && requestedShow == null && returnId != null && requestIsCurrent()) {
            val index = results.indexOfFirst { it.id == returnId }
            if (grid.layoutInfo.visibleItemsInfo.none { it.key == returnId }) grid.scrollToItem(index)
        }
    }
    LaunchedEffect(requestedRestore, requestedShow, returnId, requestedResultReady, requestedQueryReady, windowFocused, request) {
        if (requestedRestore && requestedShow == null && windowFocused && requestIsCurrent()) {
            if (returnId != null && requestedResultReady && resultFocus.requestFocus()) { restore = false; holdingFocus = false }
            else if (returnId == null && requestedQueryReady) {
                // A newly attached text editor may defer focus during layout or an
                // IME transition. Release the holder only after the field owns focus.
                while (restore && requestIsCurrent() && window.isWindowFocused && !fieldFocused) {
                    queryFocus.requestFocus()
                    if (!fieldFocused) withFrameNanos { }
                }
                if (requestIsCurrent() && fieldFocused) { restore = false; holdingFocus = false }
            }
        }
    }

    Box(Modifier.fillMaxSize().focusRequester(transitionFocus).onFocusChanged { holderFocused = it.isFocused }
        .focusProperties { canFocus = holdingFocus }.focusable()) {
    if (selectedShow != null) {
        TVShowBrowser(emptyList(), onOpen, initialShowId = selectedShow, preparedShows = catalog.shows,
            onExit = { holdFocus(); selectedShow = null; restore = true }, restoreNavigationFocus = true,
            onNavigationFocusReady = { if (requestIsCurrent()) holdingFocus = false })
    } else {
    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        ScreenHeader("Search", Modifier.padding(horizontal = ScreenPadding))
        TvTextField(query, {
            focusRequest++; query = it; originId = null; originEpisode = null; restore = false
            scope.launch { grid.scrollToItem(0) }
        }, "Titles, shows, genres, files", Modifier.padding(horizontal = ScreenPadding).fillMaxWidth()
            .testTag("library-search-field").focusRequester(queryFocus).onFocusChanged { fieldFocused = it.isFocused }
            .onGloballyPositioned { queryReady = true },
            imeAction = ImeAction.Search)
        when {
            query.isBlank() -> EmptyState("Search your collection", "Find a show, a specific episode, a movie or a photo.")
            results.isEmpty() -> EmptyState("No results", "Try a show title, episode name or file name.")
            else -> {
                Text("${results.size} ${if (results.size == 1) "result" else "results"}",
                    Modifier.padding(horizontal = ScreenPadding), color = SecondaryText)
                LazyVerticalGrid(GridCells.Adaptive(148.dp), Modifier.weight(1f).testTag("library-search-results"), state = grid,
                    contentPadding = PaddingValues(start = ScreenPadding, end = ScreenPadding, top = 8.dp, bottom = 48.dp),
                    horizontalArrangement = Arrangement.spacedBy(28.dp), verticalArrangement = Arrangement.spacedBy(28.dp)) {
                    items(results, key = { it.id }) { result ->
                        val cardModifier = Modifier.testTag("search-result:${result.id}").onFocusChanged {
                            if (it.isFocused) focusedResult = result.id
                            else if (focusedResult == result.id) focusedResult = null
                        }.then(if (result.id == returnId)
                            Modifier.focusRequester(resultFocus).onGloballyPositioned { resultReady = true } else Modifier)
                        val open = {
                            originId = result.id
                            when (result) {
                                is LibrarySearchResult.Show -> {
                                    holdFocus()
                                    originEpisode = result.show.episodes.first().id
                                    selectedShow = result.show.id
                                }
                                is LibrarySearchResult.Media -> { originEpisode = result.item.id; onOpen(result.item) }
                            }
                        }
                        when (result) {
                            is LibrarySearchResult.Show -> TVArtworkCard(result.title, result.subtitle, result.show.posterPath,
                                cardModifier = cardModifier, onClick = open)
                            is LibrarySearchResult.Media -> if (result.item.isPhoto) PhotoTile(result.item, cardModifier, onClick = open)
                            else TVArtworkCard(result.title, result.item.episodeInfo?.let {
                                "${result.item.seriesTitle ?: it.seriesTitle} · S${it.season} E${it.episode}"
                            } ?: result.item.year?.toString() ?: result.item.mediaKind.label, result.item.posterPath,
                                cardModifier = cardModifier, onClick = open)
                        }
                    }
                }
            }
        }
    }
    }
    }
}
