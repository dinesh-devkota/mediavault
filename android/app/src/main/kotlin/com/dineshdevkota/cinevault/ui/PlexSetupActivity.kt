@file:OptIn(androidx.tv.material3.ExperimentalTvMaterial3Api::class)

package com.dineshdevkota.cinevault.ui

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.room.withTransaction
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import com.dineshdevkota.cinevault.container
import com.dineshdevkota.cinevault.data.SourceEntity
import com.dineshdevkota.cinevault.plex.PLEX
import com.dineshdevkota.cinevault.plex.PlexConnectionManager
import com.dineshdevkota.cinevault.plex.PlexConnectionStorage
import com.dineshdevkota.cinevault.plex.PlexException
import com.dineshdevkota.cinevault.plex.PlexMediaClient
import com.dineshdevkota.cinevault.plex.SavedPlexServer
import com.dineshdevkota.cinevault.plex.plexLibraryTypes
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.UUID

internal class PlexSetupActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!container.family.current.admin) { finish(); return }
        setCineVaultContent { PlexSetup(intent.getStringExtra(SOURCE_ID), ::finish) }
    }

    companion object {
        private const val SOURCE_ID = "source_id"
        fun start(context: Context, sourceId: String? = null) {
            context.startActivity(Intent(context, PlexSetupActivity::class.java).putExtra(SOURCE_ID, sourceId))
        }
    }
}

/** A verified credential stays in this draft until the Admin selects the library to save. */
private class PlexDraft : PlexConnectionStorage {
    @Volatile private var value: SavedPlexServer? = null
    override fun read() = value
    override fun save(server: SavedPlexServer) { value = server }
    override fun clear() { value = null }
}

@Composable
private fun PlexSetup(sourceId: String?, close: () -> Unit) {
    val container = LocalContext.current.container
    val family = container.family
    val session by family.session.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val sourceKey = remember(sourceId) { sourceId?.let(UUID::fromString) ?: UUID.randomUUID() }
    val draft = remember { PlexDraft() }
    val manager = remember(session, sourceKey) {
        val openingSession = session
        val owner = UUID.randomUUID()
        PlexConnectionManager(
            { owner.takeIf { openingSession.admin && family.isCurrent(openingSession) } },
            draft,
            sourceKey,
        )
    }
    var existing by remember { mutableStateOf<SourceEntity?>(null) }
    var name by remember { mutableStateOf("") }
    var ready by remember { mutableStateOf(sourceId == null) }
    var request by remember { mutableStateOf<Job?>(null) }
    var code by remember { mutableStateOf<PlexConnectionManager.LinkCode?>(null) }
    var servers by remember { mutableStateOf(emptyList<PlexConnectionManager.ServerChoice>()) }
    var libraries by remember { mutableStateOf(emptyList<PlexMediaClient.Library>()) }
    var confirmRemoval by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(session) { if (!session.admin) close() }
    LaunchedEffect(sourceId) {
        if (sourceId == null) return@LaunchedEffect
        existing = container.database.sources().get(sourceId)?.takeIf { it.sourceType == PLEX }
        val saved = existing
        if (saved == null) close() else {
            name = saved.name
            ready = true
        }
    }
    DisposableEffect(draft) { onDispose { draft.clear() } }
    if (!session.admin || !ready) return

    fun submit(action: suspend (() -> Unit) -> Unit) {
        if (request != null) return
        val owner = session
        val authorize = {
            family.requireAdmin()
            check(family.isCurrent(owner)) { "Unlock Admin again to manage Plex." }
        }
        error = null
        request = scope.launch {
            try { authorize(); action(authorize) }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: PlexException) { error = failure.message }
            catch (_: Exception) { error = "Could not reach or save Plex. Check your server connection and try again." }
            finally { request = null; code = null }
        }
    }

    fun begin() = submit { authorize ->
        draft.clear()
        servers = emptyList()
        libraries = emptyList()
        val link = manager.start()
        code = link
        while (servers.isEmpty()) {
            delay(2_000)
            authorize()
            when (val result = manager.poll()) {
                PlexConnectionManager.LinkStatus.AwaitingAuthorization -> Unit
                is PlexConnectionManager.LinkStatus.ChooseServer -> {
                    servers = result.servers.filter { existing == null || it.id == existing?.username }
                    if (servers.isEmpty()) throw PlexException("No matching Plex server with an HTTPS connection is available.")
                }
            }
        }
    }

    fun choose(server: PlexConnectionManager.ServerChoice, endpoint: String) = submit { authorize ->
        val selected = manager.select(server.id, endpoint)
        authorize()
        val saved = existing
        libraries = selected.libraries.distinctBy { it.key }.filter {
            it.type in plexLibraryTypes && (saved == null || it.key == saved.share)
        }
        if (libraries.isEmpty()) throw PlexException("This server did not offer the selected library. Link Plex again.")
        servers = emptyList()
    }

    fun save(library: PlexMediaClient.Library) = submit { authorize ->
        val server = draft.read() ?: throw PlexException("Link Plex again before saving this library.")
        val saved = existing
        val encrypted = withContext(Dispatchers.IO) { container.secrets.encrypt(server.serverToken) }
        val id = sourceKey.toString()
        val updated = SourceEntity(
            id = id, name = name.trim().ifEmpty { library.title }, host = server.endpoint,
            share = library.key, username = server.serverID, encryptedPassword = encrypted,
            lastScanAt = saved?.lastScanAt, sourceType = PLEX,
        )
        container.database.withTransaction {
            authorize()
            val current = container.database.sources().get(id)
            check(current?.copy(lastScanAt = saved?.lastScanAt) == saved) { "This Plex source changed. Open it again." }
            container.database.sources().upsert(updated.copy(lastScanAt = current?.lastScanAt))
        }
        draft.clear()
        container.scope.launch { container.scanner.scan(id) }
        close()
    }

    fun rename() = submit { authorize ->
        val saved = existing ?: return@submit
        val label = name.trim()
        if (label.isEmpty()) throw PlexException("Enter a name for this source.")
        container.database.withTransaction {
            authorize()
            val current = container.database.sources().get(saved.id)
            check(current?.copy(lastScanAt = saved.lastScanAt) == saved) { "This Plex source changed. Open it again." }
            container.database.sources().upsert(checkNotNull(current).copy(name = label))
        }
        close()
    }

    fun remove() = submit { authorize ->
        val saved = existing ?: return@submit
        container.database.withTransaction {
            authorize()
            val current = container.database.sources().get(saved.id)
            check(current?.copy(lastScanAt = saved.lastScanAt) == saved) { "This Plex source changed. Open it again." }
            container.database.sources().delete(saved.id)
        }
        draft.clear()
        close()
    }

    BackHandler(enabled = request != null) { request?.cancel() }
    LazyColumn(contentPadding = PaddingValues(ScreenPadding), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item {
            Text(if (existing == null) "Connect Plex" else "Reconnect Plex", style = MaterialTheme.typography.headlineLarge)
            existing?.let { Text(it.name, color = SecondaryText) }
        }
        code?.let { link -> item {
            Text("On another device, open plex.tv/link and enter this code:")
            Text(link.code, style = MaterialTheme.typography.displayMedium)
            Text("The code expires in ${link.expiresInSeconds} seconds.", color = SecondaryText)
        } }
        if (request != null) {
            item { OutlinedButton(onClick = { request?.cancel() }) { Text("Cancel") } }
        } else {
            if (existing != null || libraries.isNotEmpty()) {
                item { TvTextField(name, { name = it.take(120) }, "Source name (optional)") }
            }
            if (servers.isNotEmpty()) item { Text("Choose a Plex server and connection") }
            for (server in servers) {
                val connections = server.connections.sortedWith(
                    compareBy<PlexConnectionManager.ConnectionChoice> { it.relay }.thenByDescending { it.local })
                    .distinctBy { it.endpoint }
                items(connections, key = { server.id + it.endpoint }) { choice ->
                    val route = when { choice.relay -> "Relay"; choice.local -> "Local"; else -> "Remote" }
                    OutlinedButton(onClick = { choose(server, choice.endpoint) }) {
                        Text("${server.name} · $route\n${choice.endpoint}")
                    }
                }
            }
            if (libraries.isNotEmpty()) item { Text("Choose the library to import") }
            items(libraries, key = { it.key }) { library ->
                Button(onClick = { save(library) }) { Text(library.title) }
            }
            item { Button(onClick = { begin() }) { Text(if (servers.isEmpty() && libraries.isEmpty()) "Get Plex link code" else "Link again") } }
            existing?.let { saved -> item {
                OutlinedButton(enabled = name.isNotBlank() && name.trim() != saved.name, onClick = { rename() }) {
                    Text("Save source name")
                }
            } }
            if (existing != null) item {
                OutlinedButton(onClick = {
                    if (confirmRemoval) remove() else confirmRemoval = true
                }) { Text(if (confirmRemoval) "Confirm remove Plex source" else "Sign out and remove source") }
            }
            item { OutlinedButton(onClick = close) { Text("Back") } }
        }
        error?.let { message -> item { Text(message, color = ErrorText) } }
    }
}
