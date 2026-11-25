package com.dineshdevkota.cinevault.ui

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import com.dineshdevkota.cinevault.container
import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.library.MediaCollection
import com.dineshdevkota.cinevault.library.groupMovieVersions
import com.dineshdevkota.cinevault.library.movieVersionKey
import com.dineshdevkota.cinevault.library.versionDescription
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

class MediaCollectionsActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) { super.onCreate(savedInstanceState); setCineVaultContent { CollectionsScreen() } }
    companion object { fun start(context: Context) = context.startActivity(Intent(context, MediaCollectionsActivity::class.java)) }
}

@Composable
private fun CollectionsScreen() {
    val context = LocalContext.current
    val container = context.container
    val collections by remember { container.collections.observeAll() }.collectAsStateWithLifecycle(emptyList())
    var selectedId by remember { mutableStateOf<String?>(null) }
    var create by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<MediaCollection?>(null) }
    var selectedShow by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val fetching by container.metadata.isRunning.collectAsStateWithLifecycle()
    val metadataStatus by container.metadata.status.collectAsStateWithLifecycle()
    var refreshError by remember { mutableStateOf<String?>(null) }
    val selected = collections.firstOrNull { it.id == selectedId }
    val cards = remember(selected) { collectionItems(selected?.movies.orEmpty()) }
    val shows = cards.filterIsInstance<CollectionItem.Show>().map { it.show }
    BackHandler(selectedId != null && selectedShow == null) { selectedId = null }
    LaunchedEffect(collections, selectedId) { if (selectedId != null && selected == null) selectedId = null }
    if (selectedShow != null && selected != null) {
        TVShowBrowser(emptyList(), { MovieDetailActivity.start(context, it.id) }, initialShowId = selectedShow,
            preparedShows = shows, onExit = { selectedShow = null })
    } else Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        ScreenHeader(selected?.name ?: "Collections", Modifier.padding(horizontal = ScreenPadding))
        AdaptiveActions(modifier = Modifier.padding(horizontal = ScreenPadding)) {
            if (selected != null) {
                OutlinedButton(onClick = { selectedId = null }) { Text("All collections") }
                if (selected.custom) OutlinedButton(onClick = { editing = selected }) { Text("Edit collection") }
            } else {
                Button(onClick = { create = true }, modifier = Modifier.testTag("create-collection")) { Text("New collection") }
                if (container.family.current.admin) OutlinedButton(enabled = !fetching, onClick = {
                    val session = container.family.current
                    refreshError = null
                    scope.launch { try {
                        container.metadata.refreshMovieCollections { check(container.family.isCurrent(session) && session.admin) { "The profile changed. Try again." } }
                    } catch (cancelled: CancellationException) { throw cancelled }
                    catch (failure: Exception) { refreshError = failure.message ?: "Could not find movie series. Try again." } }
                }) { Text(if (fetching) "Finding movie series…" else "Find movie series") }
            }
        }
        if (selected == null) (refreshError ?: metadataStatus)?.let { Text(it, modifier = Modifier.padding(horizontal = ScreenPadding), color = SecondaryText) }
        if (selected == null) {
            if (collections.isEmpty()) EmptyState("Make room for your favorites", "Create a collection, then add titles from their details or select several in Library. Movie series from TMDB or local NFO files appear here automatically.", Modifier.padding(ScreenPadding))
            LazyColumn(contentPadding = PaddingValues(ScreenPadding), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                items(collections, key = { it.id }) { collection ->
                    OutlinedButton(onClick = { selectedId = collection.id }, modifier = Modifier.fillMaxWidth().testTag("collection:${collection.name}")) {
                        Column { Text(collection.name); Text("${collectionItems(collection.movies).size} titles · ${if (collection.custom) "Your collection" else "Movie series"}", color = SecondaryText) }
                    }
                }
            }
        } else {
            if (selected.movies.isEmpty()) EmptyState("No titles in this collection", "Open a title and choose Collections to add it. Unavailable or restricted titles stay hidden.", Modifier.padding(ScreenPadding))
            LazyVerticalGrid(GridCells.Adaptive(if (LocalTvLayout.current) 168.dp else 140.dp), contentPadding = PaddingValues(ScreenPadding),
                horizontalArrangement = Arrangement.spacedBy(20.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
                items(cards, key = { it.id }) { item ->
                    when (item) {
                        is CollectionItem.Movie -> PosterCard(item.movie, onClick = { MovieDetailActivity.start(context, item.movie.id) },
                            versionCount = selected.movies.count { movieVersionKey(it) == movieVersionKey(item.movie) })
                        is CollectionItem.Show -> TVArtworkCard(item.show.title, "${item.show.seasons.size} seasons", item.show.posterPath,
                            artworkMovie = item.show.episodes.firstOrNull(), onClick = { selectedShow = item.show.id })
                    }
                }
            }
        }
    }
    if (create) CollectionPicker(emptySet()) { create = false }
    editing?.let { item -> CollectionEditor(item) { editing = null } }
}

@Composable
private fun CollectionEditor(collection: MediaCollection, close: () -> Unit) {
    val store = LocalContext.current.container.collections
    var name by remember(collection.id) { mutableStateOf(collection.name) }
    var error by remember { mutableStateOf<String?>(null) }
    var remove by remember { mutableStateOf(false) }
    CollectionDialog(close) {
        Text(if (remove) "Delete this collection?" else "Edit collection", style = MaterialTheme.typography.headlineSmall)
        if (remove) Text("The collection is removed only for this profile. Your media files and viewing history are kept.")
        else TvTextField(name, { name = it }, "Collection name", Modifier.fillMaxWidth())
        error?.let { Text(it, color = ErrorText) }
        AdaptiveActions {
            Button(onClick = { try { if (remove) store.delete(collection.id) else store.rename(collection.id, name); close() } catch (e: Exception) { error = e.message } }) { Text(if (remove) "Delete collection" else "Save name") }
            OutlinedButton(onClick = close) { Text("Cancel") }
        }
        if (!remove) OutlinedButton(onClick = { remove = true }) { Text("Delete collection") }
    }
}

@Composable
internal fun CollectionPicker(movieIds: Set<String>, close: () -> Unit) {
    val container = LocalContext.current.container
    val collections by remember { container.collections.observeCustom() }.collectAsStateWithLifecycle(emptyList())
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf(false) }
    fun perform(action: suspend () -> Unit) { saving = true; error = null; scope.launch {
        try { action(); close() } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) { error = failure.message ?: "Could not save your collection." } finally { saving = false }
    } }
    CollectionDialog({ if (!saving) close() }) {
        Text(if (movieIds.isEmpty()) "New collection" else "Collections", style = MaterialTheme.typography.headlineSmall)
        Text("Collections belong to the current profile. Media stays in its original folder.", color = SecondaryText)
        if (movieIds.isNotEmpty()) collections.forEach { collection ->
            val included = collection.movieIds.containsAll(movieIds)
            OutlinedButton(enabled = !saving, onClick = { perform { container.collections.setMembers(collection.id, movieIds, !included) } },
                modifier = Modifier.fillMaxWidth().testTag("collection-choice:${collection.name}")) {
                Text("${if (included) "Remove from" else "Add to"} ${collection.name}")
            }
        }
        TvTextField(name, { name = it }, "New collection name", Modifier.fillMaxWidth(), enabled = !saving)
        error?.let { Text(it, color = ErrorText) }
        AdaptiveActions {
            Button(enabled = !saving && name.trim().isNotEmpty(), onClick = { perform { container.collections.create(name, movieIds) } }, modifier = Modifier.testTag("save-collection")) { Text(if (movieIds.isEmpty()) "Create" else "Create & add") }
            OutlinedButton(enabled = !saving, onClick = close) { Text("Cancel") }
        }
    }
}

@Composable
private fun CollectionDialog(close: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    Dialog(onDismissRequest = close) {
        Column(Modifier.widthIn(max = 620.dp).fillMaxWidth().background(SurfaceColor, RoundedCornerShape(16.dp))
            .padding(if (LocalTvLayout.current) 28.dp else 16.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(16.dp), content = content)
    }
}

@Composable
internal fun VersionChoices(current: MovieEntity) {
    val context = LocalContext.current
    val container = context.container
    val all by remember { container.library.observeAll() }.collectAsStateWithLifecycle(emptyList())
    val sources by remember { container.library.observeSources() }.collectAsStateWithLifecycle(emptyList())
    val sourceNames = sources.associate { it.id to it.name }
    val versions = remember(current, all, sources) { com.dineshdevkota.cinevault.library.watchStatusItems(all, sources)
        .filter { !it.isHidden && movieVersionKey(it) == movieVersionKey(current) } }
    var choosing by remember(current.id) { mutableStateOf(false) }
    if (versions.size > 1) {
        OutlinedButton(onClick = { choosing = true }, modifier = Modifier.testTag("choose-version")) { Text("Version: ${versionDescription(current)} · ${versions.size} available") }
        if (choosing) CollectionDialog({ choosing = false }) {
            Text("Choose a version", style = MaterialTheme.typography.headlineSmall)
            Text("Each file keeps its own playback progress.", color = SecondaryText)
            versions.forEach { movie ->
                OutlinedButton(onClick = { choosing = false; if (movie.id != current.id) MovieDetailActivity.start(context, movie.id) }, modifier = Modifier.fillMaxWidth().testTag("version:${movie.id}")) {
                    Column { Text("${if (movie.id == current.id) "✓ " else ""}${versionDescription(movie)}")
                        Text("${sourceNames[movie.sourceId].orEmpty()} · ${movie.fileName}", color = SecondaryText)
                        if (movie.isInProgress) Text("Resume ${formatDuration(movie.playbackPositionMs)}")
                    }
                }
            }
            OutlinedButton(onClick = { choosing = false }) { Text("Back") }
        }
    }
}
