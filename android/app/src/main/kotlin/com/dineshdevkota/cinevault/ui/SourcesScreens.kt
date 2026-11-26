@file:OptIn(ExperimentalTvMaterial3Api::class, ExperimentalLayoutApi::class)

package com.dineshdevkota.cinevault.ui

import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import com.dineshdevkota.cinevault.cloud.GOOGLE_DRIVE_DOCUMENTS
import com.dineshdevkota.cinevault.cloud.GoogleDriveDocuments
import com.dineshdevkota.cinevault.cloud.ONEDRIVE
import com.dineshdevkota.cinevault.container
import com.dineshdevkota.cinevault.BuildConfig
import com.dineshdevkota.cinevault.cloud.DROPBOX
import com.dineshdevkota.cinevault.core.NasAddress
import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.data.SourceEntity
import com.dineshdevkota.cinevault.jellyfin.JELLYFIN
import com.dineshdevkota.cinevault.nfs.NFS
import com.dineshdevkota.cinevault.plex.PLEX
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
fun SourcesTab(movies: List<MovieEntity>) {
    if (!LocalContext.current.container.family.current.admin) { AdminRequired(); return }
    val context = LocalContext.current
    val container = context.container
    val sources by remember { container.library.observeSources() }.collectAsStateWithLifecycle(emptyList())
    val scanning by container.scanner.isScanning.collectAsStateWithLifecycle()
    val status by container.scanner.status.collectAsStateWithLifecycle()
    val driveAvailable = remember(context) {
        GoogleDriveDocuments.canPick(context, Intent.ACTION_OPEN_DOCUMENT_TREE) ||
            GoogleDriveDocuments.canPick(context, Intent.ACTION_OPEN_DOCUMENT)
    }
    val counts = remember(movies) { movies.filter { !it.isMissing }.groupingBy { it.sourceId }.eachCount() }

    LazyColumn(
        contentPadding = PaddingValues(start = ScreenPadding, end = ScreenPadding, bottom = 48.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item { ScreenHeader("Sources") }
        item {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Button(onClick = { NasSetupActivity.start(context) }) { Text("Add NAS Source") }
                OutlinedButton(onClick = { JellyfinSetupActivity.start(context) }) { Text("Connect Jellyfin") }
                OutlinedButton(onClick = { PlexSetupActivity.start(context) }) { Text("Connect Plex") }
                OutlinedButton(onClick = { OneDriveSetupActivity.start(context) }) { Text("Connect OneDrive") }
                OutlinedButton(onClick = { DropboxSetupActivity.start(context) }) { Text("Connect Dropbox") }
                if (driveAvailable) OutlinedButton(onClick = { GoogleDriveSetupActivity.start(context) }) { Text("Add Google Drive") }
                if (container.nfs != null) OutlinedButton(onClick = { NfsSetupActivity.start(context) }) { Text("Connect NFS") }
                OutlinedButton(
                    onClick = { container.scope.launch { container.scanner.scanAll() } },
                    enabled = !scanning && sources.any { it.sourceType != NFS || container.nfs != null },
                ) {
                    Text(if (scanning) "Scanning…" else "Rescan All")
                }
            }
        }
        status?.let { note ->
            item {
                NasStatusPanel(
                    if (scanning) "Updating your library" else "Latest scan",
                    note, working = scanning,
                    error = !scanning && (note.startsWith("Scan failed") || note.startsWith("Could not")),
                )
            }
        }
        if (sources.isEmpty()) {
            item { EmptyState("No sources yet", "Connect a source and choose a media folder or library.") }
        }
        items(sources, key = { it.id }) { source ->
            SourceRow(
                source,
                count = counts[source.id] ?: 0,
                scanning = scanning,
                available = source.sourceType != NFS || container.nfs != null,
                onScan = { container.scope.launch { container.scanner.scan(source.id) } },
                onEdit = {
                    when (source.sourceType) {
                        JELLYFIN -> JellyfinSetupActivity.start(context, source.id)
                        PLEX -> PlexSetupActivity.start(context, source.id)
                        ONEDRIVE -> OneDriveSetupActivity.start(context, source.id)
                        DROPBOX -> DropboxSetupActivity.start(context, source.id)
                        GOOGLE_DRIVE_DOCUMENTS -> GoogleDriveSetupActivity.start(context, source.id)
                        NFS -> NfsSetupActivity.start(context, source.id)
                        else -> SourceEditorActivity.start(context, source.id)
                    }
                },
            )
        }
    }
}

@Composable
private fun SourceRow(source: SourceEntity, count: Int, scanning: Boolean, available: Boolean, onScan: () -> Unit, onEdit: () -> Unit) {
    val details: @Composable (Modifier) -> Unit = { modifier ->
        Column(modifier) {
            Text(source.name, style = MaterialTheme.typography.titleMedium)
            Text(sourceUrl(source), style = MaterialTheme.typography.bodyMedium, color = SecondaryText)
            Text(
                if (available) "$count items · ${source.lastScanAt?.let { "Last scanned ${formatDate(it)}" } ?: "Ready for first scan"}"
                else "Unavailable in this build",
                style = MaterialTheme.typography.labelMedium,
                color = SecondaryText,
            )
        }
    }
    val controls: @Composable () -> Unit = {
        OutlinedButton(onClick = onScan, enabled = !scanning && available) { Text("Scan") }
        OutlinedButton(onClick = onEdit, enabled = available) { Text("Edit") }
    }
    val card = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(SurfaceColor).padding(20.dp)
    if (LocalTvLayout.current) Row(
        card, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        details(Modifier.weight(1f))
        controls()
    } else Column(card, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        details(Modifier.fillMaxWidth())
        AdaptiveActions(content = controls)
    }
}

fun sourceUrl(source: SourceEntity): String {
    if (source.sourceType == DROPBOX) return "Dropbox / ${source.rootPath}"
    if (source.sourceType == JELLYFIN || source.sourceType == PLEX) return source.host
    if (source.sourceType == ONEDRIVE) return "OneDrive · ${source.username}"
    if (source.sourceType == GOOGLE_DRIVE_DOCUMENTS) return "Google Drive · Android file picker"
    if (source.sourceType == "webdav") return listOf(source.host, source.rootPath).filter(String::isNotEmpty).joinToString(" / ")
    val address = runCatching { NasAddress.parse(source.host, source.port) }.getOrNull() ?: return "Invalid NAS address"
    if (source.sourceType == NFS) return "nfs://${address.authority}" +
        if (source.rootPath.isEmpty()) source.share else "${source.share.trimEnd('/')}/${source.rootPath}"
    return "smb://" + listOf(address.authority, source.share, source.rootPath).filter { it.isNotEmpty() }.joinToString("/")
}

@Composable
fun SettingsTab() {
    if (!LocalContext.current.container.family.current.admin) {
        Column(Modifier.padding(ScreenPadding), verticalArrangement = Arrangement.spacedBy(20.dp)) {
            HouseholdButton()
            Text("Shared settings are managed by Admin.", color = SecondaryText)
        }
        return
    }
    val context = LocalContext.current
    val container = context.container
    val settings = container.settings
    val metadata = container.metadata
    val scope = rememberCoroutineScope()
    var apiKey by remember { mutableStateOf("") }
    var keyLoaded by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    val fetching by metadata.isRunning.collectAsStateWithLifecycle()
    val status by metadata.status.collectAsStateWithLifecycle()

    LaunchedEffect(settings) {
        try {
            apiKey = withContext(Dispatchers.IO) { settings.tmdbApiKey }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            message = e.message ?: "Could not read the saved TMDB key. Enter it again."
        } finally {
            keyLoaded = true
        }
    }

    LazyColumn(
        contentPadding = PaddingValues(start = ScreenPadding, end = ScreenPadding, bottom = 48.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item { ScreenHeader("Settings", kicker = "MEDIAVAULT",
            trailing = "Version ${BuildConfig.VERSION_NAME} · Build ${BuildConfig.VERSION_CODE}") }
        item { HouseholdButton() }
        item {
            AdaptiveActions() {
                OutlinedButton(onClick = { MediaGuideActivity.start(context) }) { Text("Media Guide & Help") }
                OutlinedButton(onClick = { PlaybackSettingsActivity.start(context) }) { Text("Playback & Subtitles") }
            }
        }
        item { Text("Metadata (themoviedb.org)", style = MaterialTheme.typography.titleLarge) }
        item {
            if (!keyLoaded) Text("Loading saved key…", color = SecondaryText)
            else TvTextField(
                apiKey,
                { apiKey = it },
                "TMDB API key or read access token",
                Modifier.width(640.dp),
                isPassword = true,
                imeAction = ImeAction.Done,
            )
        }
        item {
            AdaptiveActions() {
                Button(enabled = keyLoaded && !saving, onClick = {
                    val newKey = apiKey
                    saving = true
                    metadata.clearStatus()
                    scope.launch {
                        try {
                            withContext(Dispatchers.IO) { settings.tmdbApiKey = newKey }
                            if (newKey.isBlank()) {
                                message = "TMDB key removed."
                            } else {
                                message = "Fetching metadata…"
                                container.scope.launch { metadata.fetchMissing() }
                            }
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            message = "Could not save the TMDB key. ${e.message.orEmpty()}"
                        } finally {
                            saving = false
                        }
                    }
                }) {
                    Text("Save Key & Fetch Missing Metadata")
                }
                OutlinedButton(
                    onClick = {
                        metadata.clearStatus()
                        message = "Refreshing metadata…"
                        container.scope.launch { metadata.refreshAll() }
                    },
                    enabled = keyLoaded && !saving && !fetching,
                ) {
                    Text(if (fetching) "Updating Metadata…" else "Refresh All Metadata")
                }
            }
        }
        item {
            Text(
                status ?: message ?: ("Get a free key at themoviedb.org → Settings → API. Posters and details are " +
                    "fetched automatically after each scan."),
                color = SecondaryText,
            )
        }
        item { Text("About", style = MaterialTheme.typography.titleLarge) }
        item {
            Text(
                "MediaVault streams MP4, MKV, WebM, AVI, TS and more directly from your NAS over SMB. " +
                    "Which video and audio codecs play depends on your TV device.",
                color = SecondaryText,
            )
        }
        item {
            Text("This product uses the TMDB API but is not endorsed or certified by TMDB.", color = SecondaryText)
        }
    }
}
