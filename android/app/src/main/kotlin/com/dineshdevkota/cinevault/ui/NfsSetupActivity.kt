package com.dineshdevkota.cinevault.ui

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import androidx.room.withTransaction
import androidx.tv.material3.Text
import com.dineshdevkota.cinevault.container
import com.dineshdevkota.cinevault.core.NasAddress
import com.dineshdevkota.cinevault.data.SourceEntity
import com.dineshdevkota.cinevault.nfs.NFS
import com.dineshdevkota.cinevault.nfs.NfsMedia
import com.dineshdevkota.cinevault.smb.SmbService
import com.dineshdevkota.cinevault.smb.SourceConfig
import com.dineshdevkota.cinevault.webdav.DavAddress
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.UUID

internal class NfsSetupActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val family = container.family
        val epoch = family.authenticationEpoch
        val owner = family.current
        fun canManage() = container.nfs != null && owner.admin &&
            family.isCurrent(owner) && family.authenticationEpoch == epoch
        if (!canManage()) return finish()
        fun requireOwner() {
            if (!canManage()) throw SecurityException("Unlock Admin to manage NFS sources.")
        }

        lifecycleScope.launch {
            combine(family.session, family.authenticationEpochs) { _, _ -> canManage() }
                .collect { if (!it) finish() }
        }
        lifecycleScope.launch {
            val sourceId = intent.getStringExtra(SOURCE_ID)
            val original = sourceId?.let { container.database.sources().get(it) }
            if (!canManage() || (sourceId != null && original?.sourceType != NFS)) return@launch finish()
            setCineVaultContent { NfsSetupScreen(original, ::requireOwner, ::finish) }
        }
    }

    companion object {
        private const val SOURCE_ID = "nfs_source_id"

        fun start(context: Context, sourceId: String? = null) {
            if (context.container.nfs == null || !context.container.family.current.admin) return
            context.startActivity(Intent(context, NfsSetupActivity::class.java).putExtra(SOURCE_ID, sourceId))
        }
    }
}

private data class VerifiedNfsFolder(val config: SourceConfig, val children: List<String>)

@Composable
private fun NfsSetupScreen(original: SourceEntity?, requireOwner: () -> Unit, close: () -> Unit) {
    val container = LocalContext.current.container
    val scope = rememberCoroutineScope()
    val draftId = remember { UUID.randomUUID().toString() }
    val draft = remember { NfsMedia(authorize = { _, _, _ -> { requireOwner() } }) }
    var name by remember { mutableStateOf(original?.name.orEmpty()) }
    var server by remember {
        mutableStateOf(original?.let {
            val host = if (':' in it.host) "[${it.host}]" else it.host
            host + it.port?.let { port -> ":$port" }.orEmpty()
        }.orEmpty())
    }
    var exportPath by remember { mutableStateOf(original?.share.orEmpty()) }
    var selected by remember { mutableStateOf<VerifiedNfsFolder?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var removeRequested by remember { mutableStateOf(false) }

    fun run(work: suspend () -> Unit) {
        busy = true
        error = null
        scope.launch {
            try { requireOwner(); work() }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { error = SmbService.describe(failure) }
            finally { busy = false }
        }
    }

    fun sameLocation(config: SourceConfig) = original?.let {
        it.host == config.host && it.port == config.port && it.share == config.share && it.rootPath == config.rootPath
    } == true

    suspend fun browse(config: SourceConfig, path: String) {
        val children = draft.browse(config.copy(rootPath = ""), path).filter { it.isDirectory }.map { it.name }
        requireOwner()
        selected = VerifiedNfsFolder(config.copy(rootPath = path), children)
    }

    suspend fun updateSource(replacement: SourceEntity?) {
        val sources = container.database.sources()
        if (original != null) {
            container.smb.reset(original.id)
            container.photos.resetSource(original.id)
        }
        try {
            container.database.withTransaction {
                requireOwner()
                if (original != null) {
                    val current = sources.get(original.id)
                    check(current?.copy(lastScanAt = original.lastScanAt) == original) {
                        "This source changed. Reopen its settings."
                    }
                    if (replacement?.id != original.id) sources.delete(original.id)
                }
                replacement?.let { sources.upsert(it) }
                requireOwner()
            }
        } finally {
            if (original != null) withContext(NonCancellable) {
                container.smb.reset(original.id)
                container.photos.resetSource(original.id)
            }
        }
    }

    LazyColumn(contentPadding = PaddingValues(ScreenPadding), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        item { ScreenHeader(if (original == null) "Connect NFS" else "Edit NFS source") }
        item { Text("NFSv3 · Read-only access on a trusted local network.", color = SecondaryText) }
        item { TvTextField(name, { name = it }, "Source name", Modifier.fillMaxWidth(), enabled = !busy) }
        item { TvTextField(server, { server = it; selected = null }, "Server hostname or IP", Modifier.fillMaxWidth(), enabled = !busy) }
        item { TvTextField(exportPath, { exportPath = it; selected = null }, "Export path (for example /media)", Modifier.fillMaxWidth(), enabled = !busy) }
        item {
            AdaptiveActions {
                Button(enabled = !busy, onClick = { run {
                    selected = null
                    require(server.none { it == '/' || it == '\\' }) { "Enter the NFS server hostname or IP address." }
                    val address = NasAddress.parse(server)
                    val export = exportPath.trim()
                    require(export.startsWith('/') && (export == "/" || DavAddress.contains(export.drop(1), ""))) {
                        "Enter an absolute NFS export path."
                    }
                    browse(SourceConfig(draftId, address.host, address.port, export, "", "", "", sourceType = NFS), "")
                } }) { Text(if (original == null) "Connect and browse" else "Reconnect and browse") }
                if (original != null) OutlinedButton(enabled = !busy, onClick = { removeRequested = !removeRequested }) {
                    Text("Remove source")
                }
            }
        }
        val folder = selected
        if (folder != null) {
            val path = folder.config.rootPath
            item { Text("Media folder · ${path.ifEmpty { "Export root" }}", color = SecondaryText) }
            if (path.isNotEmpty()) item {
                OutlinedButton(enabled = !busy, onClick = { run { browse(folder.config, path.substringBeforeLast('/', "")) } }) {
                    Text("Up one folder")
                }
            }
            if (original != null && original.rootPath.isNotEmpty() && path.isEmpty() &&
                sameLocation(folder.config.copy(rootPath = original.rootPath))) item {
                OutlinedButton(enabled = !busy, onClick = { run { browse(folder.config, original.rootPath) } }) {
                    Text("Open saved media folder")
                }
            }
            if (original != null && !sameLocation(folder.config)) item {
                Text("Changing the media location replaces this source and its library entries. Grant access to the new source separately.", color = SecondaryText)
            }
            item {
                Button(enabled = !busy && !removeRequested, onClick = { run {
                    browse(folder.config, path)
                    val config = folder.config
                    val title = name.trim().ifEmpty { config.host }
                    val replacement = if (original != null && sameLocation(config)) original.copy(name = title)
                    else SourceEntity(id = draftId, name = title, host = config.host, port = config.port,
                        share = config.share, rootPath = config.rootPath, sourceType = NFS)
                    updateSource(replacement)
                    container.scope.launch { container.scanner.scan(replacement.id) }
                    close()
                } }) { Text("Save Folder & Scan") }
            }
            items(folder.children, key = { it }) { child ->
                OutlinedButton(enabled = !busy, onClick = { run {
                    browse(folder.config, if (path.isEmpty()) child else "$path/$child")
                } }) { Text("$child ▸") }
            }
        }
        if (removeRequested) item {
            Text("Remove the library entries and playback history for this source from this device?", color = SecondaryText)
            AdaptiveActions {
                OutlinedButton(enabled = !busy, onClick = { removeRequested = false }) { Text("Keep source") }
                Button(enabled = !busy, onClick = { run { updateSource(null); close() } }) { Text("Confirm removal") }
            }
        }
        if (busy) item { Text("Checking the NFS source…", color = SecondaryText) }
        error?.let { note -> item { Text(note, color = ErrorText) } }
    }
}
