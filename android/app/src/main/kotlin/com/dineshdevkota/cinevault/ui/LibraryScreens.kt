@file:OptIn(ExperimentalTvMaterial3Api::class)

package com.dineshdevkota.cinevault.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridScope
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.tv.material3.Card
import androidx.tv.material3.CardDefaults
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Tab
import androidx.tv.material3.TabRow
import androidx.tv.material3.Text
import com.dineshdevkota.cinevault.container
import com.dineshdevkota.cinevault.core.LibraryFilter
import com.dineshdevkota.cinevault.core.LibraryFacets
import com.dineshdevkota.cinevault.core.MediaKind
import com.dineshdevkota.cinevault.core.LibraryQuery
import com.dineshdevkota.cinevault.core.LibrarySort
import com.dineshdevkota.cinevault.core.Tmdb
import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.data.SourceEntity
import com.dineshdevkota.cinevault.photos.photoAvailable
import com.dineshdevkota.cinevault.library.watchStatusItems
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private val tabs = listOf("Home", "Library", "Photos", "Search", "Sources", "Settings")

@Composable
fun RootScreen() {
    val context = LocalContext.current
    val container = context.container
    val loadedMovies by remember { container.database.movies().observeAll() }.collectAsStateWithLifecycle(initialValue = null)
    val movies = loadedMovies.orEmpty()
    var tab by rememberSaveable { mutableIntStateOf(0) }
    val tabFocus = remember { List(tabs.size) { FocusRequester() } }
    val openMovie: (MovieEntity) -> Unit = {
        if (it.isPhoto) PhotoViewerActivity.start(context, it.id) else MovieDetailActivity.start(context, it.id)
    }

    var tabRowFocused by remember { mutableStateOf(false) }
    var initialFocusRequested by remember { mutableStateOf(false) }
    var tabsPlaced by remember { mutableStateOf(false) }
    val view = LocalView.current
    val windowFocused = LocalWindowInfo.current.isWindowFocused

    fun openTab(index: Int) {
        tab = index
        tabFocus[index].requestFocus()
    }

    // Like tvOS: Back first returns to the tab bar, then to Home, then leaves the app.
    BackHandler(enabled = !tabRowFocused || tab != 0) {
        if (tabRowFocused) tab = 0
        tabFocus[tab].requestFocus()
    }
    // TabRow subcomposes its tabs during layout, after this effect can first run.
    // Wait for their placement before restoring focus. A recreated window can
    // also have focus while its Compose view does not; acquire the owner first.
    LaunchedEffect(windowFocused, tabsPlaced) {
        if (windowFocused && tabsPlaced && !initialFocusRequested) {
            // The owner's initial focus search can select another tab.
            val selectedTab = tab
            if (!view.hasFocus()) view.requestFocus()
            initialFocusRequested = tabFocus[selectedTab].requestFocus() && view.hasFocus()
        }
    }

    Column(Modifier.fillMaxSize()) {
        TabRow(
            selectedTabIndex = tab,
            modifier = Modifier
                .padding(start = ScreenPadding, top = 20.dp, bottom = 4.dp)
                .onGloballyPositioned { tabsPlaced = true }
                .onFocusChanged { tabRowFocused = it.hasFocus },
        ) {
            tabs.forEachIndexed { index, title ->
                Tab(
                    selected = index == tab,
                    onFocus = { tab = index },
                    modifier = Modifier.focusRequester(tabFocus[index]).pointerClick { tab = index },
                    onClick = { tab = index },
                ) {
                    Text(
                        title,
                        style = MaterialTheme.typography.labelLarge,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
                    )
                }
            }
        }
        Box(Modifier.weight(1f)) {
            when (tab) {
                0 -> loadedMovies?.let {
                    HomeTab(it, openMovie, openPhotos = { openTab(2) }, openSources = { openTab(4) })
                }
                1 -> MoviesTab(movies, openMovie, openSources = { openTab(4) })
                2 -> PhotosTab(movies)
                3 -> SearchTab(loadedMovies, openMovie)
                4 -> SourcesTab(movies)
                else -> SettingsTab()
            }
        }
    }
}

private enum class HomeShowCollection { ALL, WATCHLIST, UNWATCHED }

@Composable
private fun HomeTab(
    movies: List<MovieEntity>,
    onOpen: (MovieEntity) -> Unit,
    openPhotos: () -> Unit,
    openSources: () -> Unit,
) {
    var selectedShowId by rememberSaveable { mutableStateOf<String?>(null) }
    var selectedShowCollection by rememberSaveable { mutableStateOf(HomeShowCollection.ALL) }
    val context = LocalContext.current
    val container = context.container
    val status by container.scanner.status.collectAsStateWithLifecycle()
    val sources by remember { container.database.sources().observeAll() }.collectAsStateWithLifecycle(initialValue = null)
    val available = remember(movies, sources) { homeAvailableItems(movies, sources.orEmpty()) }
    val collections = remember(available) { available.groupBy { it.mediaKind } }
    val loadedSources = sources
    val continuing by produceState<List<ContinueWatchingItem>>(emptyList(), movies, loadedSources) {
        value = withContext(Dispatchers.Default) { continueWatchingItems(movies, loadedSources.orEmpty()) }
    }
    val watchlist = remember(available) { LibraryQuery.watchlist(available) }
    val unwatched = remember(available) { available.filter { !it.isWatched } }
    val featured = remember(available) {
        val fresh = available.filter { !it.isWatched && !it.isInProgress && it.mediaKind != MediaKind.MUSIC }
        fresh.firstOrNull { it.backdropPath != null } ?: fresh.firstOrNull() ?: available.firstOrNull()
    }

    if (selectedShowId != null) {
        val selectedEpisodes = when (selectedShowCollection) {
            HomeShowCollection.ALL -> collections[MediaKind.TV_SHOW].orEmpty()
            HomeShowCollection.WATCHLIST -> watchlist.filter { it.mediaKind == MediaKind.TV_SHOW }
            HomeShowCollection.UNWATCHED -> unwatched.filter { it.mediaKind == MediaKind.TV_SHOW }
        }
        TVShowBrowser(selectedEpisodes, onOpen,
            initialShowId = selectedShowId, onExit = { selectedShowId = null })
        return
    }

    LazyColumn(Modifier.testTag("home-shelves"), contentPadding = PaddingValues(bottom = 48.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
        item {
            ScreenHeader(
                "Welcome to MediaVault",
                Modifier.padding(horizontal = ScreenPadding),
                trailing = status,
            )
        }
        if (available.isEmpty()) {
            item { loadedSources?.let { EmptyHome(movies, it, openPhotos, openSources) } }
        } else {
            if (continuing.isNotEmpty()) item(key = "continue-watching") {
                ContinueWatchingRow(continuing, onOpen) { HomeCollectionActivity.start(context, HomeCollection.CONTINUE) }
            }
            if (watchlist.isNotEmpty()) item {
                CollectionRow("Watchlist", watchlist, onOpen, onSeeAll = { HomeCollectionActivity.start(context, HomeCollection.WATCHLIST) }) {
                    selectedShowCollection = HomeShowCollection.WATCHLIST
                    selectedShowId = it
                }
            }
            featured?.let { movie -> item { FeaturedCard(movie, onClick = { onOpen(movie) }) } }
            for (kind in MediaKind.entries) {
                val collection = collections[kind].orEmpty()
                if (collection.isNotEmpty()) item {
                    if (kind == MediaKind.TV_SHOW) TVShowRow(collection, onSeeAll = { HomeCollectionActivity.start(context, HomeCollection.TV_SHOWS) }) {
                        selectedShowCollection = HomeShowCollection.ALL
                        selectedShowId = it
                    }
                    else MovieRow(kind.label, collection.take(20), onOpen,
                        onSeeAll = { HomeCollection.forKind(kind)?.let { HomeCollectionActivity.start(context, it) } })
                }
            }
            if (unwatched.isNotEmpty()) item {
                CollectionRow("Unwatched", unwatched, onOpen, onSeeAll = { HomeCollectionActivity.start(context, HomeCollection.UNWATCHED) }) {
                    selectedShowCollection = HomeShowCollection.UNWATCHED
                    selectedShowId = it
                }
            }
        }
    }
}

@Composable
private fun EmptyHome(movies: List<MovieEntity>, sources: List<SourceEntity>, openPhotos: () -> Unit, openSources: () -> Unit) {
    val context = LocalContext.current
    val container = context.container
    val hasPhotos = remember(movies, sources) {
        val byId = sources.associateBy { it.id }
        movies.any { photoAvailable(it, byId[it.sourceId]) }
    }
    val scanning by container.scanner.isScanning.collectAsStateWithLifecycle()
    Column(
        Modifier.fillMaxWidth().padding(horizontal = ScreenPadding, vertical = 48.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        when {
            hasPhotos -> HomePrompt("Your photo albums are ready", "Browse your photos by folder.", "Browse Photos", openPhotos)
            sources.isEmpty() -> HomePrompt("Connect your first shared folder",
                "Choose a folder on your NAS to add movies, shows, music and photos.", "Find my NAS") { NasSetupActivity.start(context) }
            scanning -> HomePrompt("Scanning your folders", "Your media will appear as the scan finds it.", "Open Sources", openSources)
            else -> HomePrompt("No media in your library yet", "Open Sources to check your folders or scan again.", "Open Sources", openSources)
        }
    }
}

@Composable
private fun HomePrompt(title: String, detail: String, button: String, action: () -> Unit) {
    Text(title, style = MaterialTheme.typography.headlineSmall)
    Text(detail, style = MaterialTheme.typography.bodyLarge, color = SecondaryText)
    Button(onClick = action) { Text(button) }
}

@Composable
private fun FeaturedCard(movie: MovieEntity, onClick: () -> Unit) {
    Card(
        onClick = onClick,
        modifier = Modifier.padding(horizontal = ScreenPadding).fillMaxWidth().aspectRatio(21f / 7f).pointerClick(onClick = onClick),
        shape = CardDefaults.shape(RoundedCornerShape(16.dp)),
        scale = CardDefaults.scale(focusedScale = 1.02f),
    ) {
        Box(Modifier.fillMaxSize()) {
            Artwork(Tmdb.imageUrl(movie.backdropPath ?: movie.posterPath, "w1280"), "", Modifier.fillMaxSize())
            Box(
                Modifier.fillMaxSize().background(
                    Brush.horizontalGradient(0f to Color.Black.copy(alpha = 0.85f), 0.7f to Color.Transparent),
                ),
            )
            Column(Modifier.align(Alignment.CenterStart).padding(32.dp).fillMaxWidth(0.55f)) {
                Text("FEATURED", style = MaterialTheme.typography.labelLarge, color = Accent)
                Text(movie.title, style = MaterialTheme.typography.headlineMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
                movie.overview?.let {
                    Spacer(Modifier.height(8.dp))
                    Text(
                        it,
                        style = MaterialTheme.typography.bodyMedium,
                        color = SecondaryText,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            if (movie.isInProgress) {
                ProgressLine(
                    movie.progress,
                    Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(16.dp),
                )
            }
        }
    }
}

@Composable
private fun MovieGrid(minimumPosterWidth: Dp = PosterWidth, content: LazyGridScope.() -> Unit) {
    LazyVerticalGrid(
        columns = GridCells.Adaptive(minimumPosterWidth),
        contentPadding = PaddingValues(start = ScreenPadding, end = ScreenPadding, bottom = 48.dp),
        horizontalArrangement = Arrangement.spacedBy(28.dp),
        verticalArrangement = Arrangement.spacedBy(28.dp),
        content = content,
    )
}

private fun LazyGridScope.fullWidth(content: @Composable () -> Unit) {
    item(span = { GridItemSpan(maxLineSpan) }) { content() }
}

private fun LazyGridScope.posters(movies: List<MovieEntity>, onOpen: (MovieEntity) -> Unit,
    selection: WatchSelection? = null, selectable: Set<String> = emptySet()) {
    items(movies, key = { it.id }) { movie ->
        if (movie.isPhoto) PhotoTile(movie, onClick = { onOpen(movie) })
        else PosterCard(movie, selected = if (selection?.selecting == true && movie.id in selectable) movie.id in selection.ids else null,
            onClick = {
                if (selection?.selecting == true) {
                    if (movie.id in selectable) selection.toggle(listOf(movie.id))
                } else onOpen(movie)
            })
    }
}

@Composable
private fun MoviesTab(movies: List<MovieEntity>, onOpen: (MovieEntity) -> Unit, openSources: () -> Unit) {
    val container = LocalContext.current.container
    val settings = container.settings
    val sources by remember { container.database.sources().observeAll() }.collectAsStateWithLifecycle(initialValue = null)
    var sort by remember { mutableStateOf(settings.librarySort) }
    var filter by remember { mutableStateOf(settings.libraryFilter) }
    var facets by remember { mutableStateOf(settings.libraryFacets) }
    fun saveFacets(value: LibraryFacets) {
        facets = value
        settings.libraryFacets = value
    }
    var kind by remember { mutableStateOf(settings.librarySection) }
    val filterFocus = remember { FocusRequester() }
    fun clearFilters() {
        // Keep the remote on a persistent control when the empty-state button disappears.
        filterFocus.requestFocus()
        saveFacets(LibraryFacets())
        filter = LibraryFilter.ALL
        settings.libraryFilter = filter
    }
    val collection = remember(movies, kind) { movies.filter { it.mediaKind == kind } }
    val genres = remember(collection, filter, facets.genres) { (LibraryQuery.genres(collection, filter) + facets.genres).distinct().sorted() }
    val decades = remember(collection, filter, facets.decades) { (LibraryQuery.decades(collection, filter) + facets.decades).distinct().sortedDescending() }
    val sourceNames = remember(sources) { sources.orEmpty().associate { it.id to it.name } }
    // Wait for the first source result before clearing a saved selection. An empty
    // loading placeholder must not erase the user's preference on every launch.
    LaunchedEffect(sources, facets.sourceIds) {
        if (sources != null) {
            val available = facets.sourceIds.intersect(sourceNames.keys)
            if (available != facets.sourceIds) saveFacets(facets.copy(sourceIds = available))
        }
    }
    val visible = remember(collection, sort, filter, facets) {
        LibraryQuery.visible(collection, sort, filter, facets)
    }
    val tvShows = remember(visible, kind) { if (kind == MediaKind.TV_SHOW) groupTVShows(visible) else emptyList() }
    val selection = remember(kind) { WatchSelection() }
    val selectable = remember(visible, sources) { watchStatusItems(visible, sources.orEmpty()) }
    val selectableIds = remember(selectable) { selectable.map { it.id }.toSet() }
    val hasFilters = facets != LibraryFacets() || filter != LibraryFilter.ALL
    val emptyTitle = when {
        filter == LibraryFilter.WATCHLIST && facets == LibraryFacets() -> "No Watchlist titles here"
        hasFilters -> if (kind == MediaKind.MOVIE) "No matching movies" else "No matching ${kind.label.lowercase()}"
        else -> "No ${kind.label.lowercase()} yet"
    }
    val emptyMessage = when {
        filter == LibraryFilter.WATCHLIST && facets == LibraryFacets() -> "Open a title and choose Add to Watchlist to save it for later."
        hasFilters -> "Clear your filters to browse all ${kind.label.lowercase()}."
        else -> "Add the parent media folder in Sources. Its subfolders are scanned automatically."
    }
    val emptyContent: @Composable () -> Unit = {
        EmptyState(emptyTitle, emptyMessage,
            actionLabel = if (hasFilters) "Clear filters" else "Open Sources",
            onAction = if (hasFilters) ::clearFilters else openSources,
            actionModifier = Modifier.testTag("library-empty-action"))
    }

    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        ScreenHeader(
            kind.label, Modifier.padding(horizontal = ScreenPadding),
            kicker = "YOUR COLLECTION", trailing = if (kind == MediaKind.TV_SHOW)
                "${tvShows.size} ${if (tvShows.size == 1) "show" else "shows"}"
            else "${visible.size} ${if (visible.size == 1) "title" else "titles"}",
        )
        // Keep focused filters outside the recycled result items. Replacing all
        // posters with an empty state must not dispose the control being used.
        Column(
            Modifier.padding(horizontal = ScreenPadding),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                LibraryFilterMenu("Sort", setOf(sort), LibrarySort.entries, { it.label }, {
                    sort = it.single()
                    settings.librarySort = sort
                }, Modifier.weight(1f).focusRequester(filterFocus))
                LibraryFilterMenu("Show", setOf(filter), LibraryFilter.entries, { it.label }, {
                    filter = it.single()
                    settings.libraryFilter = filter
                }, Modifier.weight(1f))
                LibraryFilterMenu("Genre", facets.genres, genres, { it }, {
                    saveFacets(facets.copy(genres = it))
                }, Modifier.weight(1f), allLabel = "All genres")
            }
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                LibraryFilterMenu("Source", facets.sourceIds, sourceNames.keys.toList(), { sourceNames[it] ?: "Loading…" }, {
                    saveFacets(facets.copy(sourceIds = it))
                }, Modifier.weight(1.25f), allLabel = "All sources")
                LibraryFilterMenu("Decade", facets.decades, decades, { "${it}s" }, {
                    saveFacets(facets.copy(decades = it))
                }, Modifier.weight(1f), allLabel = "All decades")
                LibraryFilterMenu("Section", setOf(kind), MediaKind.entries.filterNot { it == MediaKind.PHOTO }, { it.label }, {
                    val selectedKind = it.single()
                    if (selectedKind != kind) {
                        kind = selectedKind
                        settings.librarySection = selectedKind
                        saveFacets(facets.copy(genres = emptySet(), decades = emptySet()))
                        filter = LibraryFilter.ALL
                        settings.libraryFilter = filter
                    }
                }, Modifier.weight(1.2f))
                OutlinedButton(
                    enabled = hasFilters,
                    onClick = ::clearFilters,
                    modifier = Modifier.testTag("library-clear-filters"),
                ) { Text("Clear filters") }
            }
        }
        if (kind != MediaKind.TV_SHOW) BulkWatchControls(selectable, "${kind.label} · Current results", selection,
            Modifier.padding(horizontal = ScreenPadding))
        Box(Modifier.weight(1f)) {
            if (kind == MediaKind.TV_SHOW) {
                TVShowBrowser(visible, onOpen, preparedShows = tvShows, emptyContent = emptyContent)
            } else {
            // Five columns on a 960dp-wide TV leave room for a complete poster
            // and its labels beneath the persistent filter controls.
            MovieGrid(minimumPosterWidth = 148.dp) {
                when {
                    visible.isEmpty() -> fullWidth { emptyContent() }
                    else -> posters(visible, onOpen, selection, selectableIds)
                }
            }
            }
        }
    }
}
