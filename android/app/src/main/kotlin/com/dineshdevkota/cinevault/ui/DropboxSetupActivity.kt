@file:OptIn(ExperimentalTvMaterial3Api::class)

package com.dineshdevkota.cinevault.ui

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.room.withTransaction
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.Text
import com.dineshdevkota.cinevault.cloud.CloudClientException
import com.dineshdevkota.cinevault.cloud.DROPBOX
import com.dineshdevkota.cinevault.cloud.DropboxAccess
import com.dineshdevkota.cinevault.cloud.DropboxClient
import com.dineshdevkota.cinevault.cloud.DropboxPath
import com.dineshdevkota.cinevault.container
import com.dineshdevkota.cinevault.data.SourceEntity
import com.dineshdevkota.cinevault.smb.SourceConfig
import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.Locale
import java.util.UUID

internal class DropboxSetupActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!container.family.current.admin) { finish(); return }
        setCineVaultContent { DropboxSetup(intent.getStringExtra(SOURCE_ID), ::finish) }
    }

    companion object {
        private const val SOURCE_ID = "source_id"

        fun start(context: Context, sourceId: String? = null) {
            context.startActivity(Intent(context, DropboxSetupActivity::class.java).putExtra(SOURCE_ID, sourceId))
        }
    }
}

private data class DropboxFolder(val id: String, val path: String) {
    val name: String get() = path.substringAfterLast('/')
}

private class PendingDropbox(
    val appKey: String,
    val client: DropboxClient,
    val credential: DropboxClient.Credentials,
    val refresh: String,
    val account: String,
) {
    val access = DropboxAccess(client, refresh, credential)
}

private suspend fun DropboxClient.revokeAttempt(credential: String) {
    try { revoke(credential) }
    catch (error: CloudClientException) {
        // An expired/revoked grant is already disconnected on Dropbox.
        if (error.statusCode != 401) throw error
    }
}

@Composable
private fun DropboxSetup(sourceId: String?, close: () -> Unit) {
    val context = LocalContext.current
    val container = context.container
    val family = container.family
    val session by family.session.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val draftId = remember { sourceId ?: UUID.randomUUID().toString() }
    var loaded by remember { mutableStateOf(sourceId == null) }
    var existing by remember { mutableStateOf<SourceEntity?>(null) }
    var sourceConfig by remember { mutableStateOf<SourceConfig?>(null) }
    var appKey by remember { mutableStateOf("") }
    var name by remember { mutableStateOf("") }
    var code by remember { mutableStateOf("") }
    var approval by remember { mutableStateOf<DropboxClient.Approval?>(null) }
    var pending by remember { mutableStateOf<PendingDropbox?>(null) }
    var stack by remember { mutableStateOf(emptyList<DropboxFolder>()) }
    var folders by remember { mutableStateOf(emptyList<DropboxFolder>()) }
    var excludesDirectories by remember { mutableStateOf(emptyList<String>()) }
    var excludesFiles by remember { mutableStateOf(emptyList<String>()) }
    var reconnecting by remember { mutableStateOf(sourceId == null) }
    var confirmingRemoval by remember { mutableStateOf(false) }
    var removed by remember { mutableStateOf(false) }
    var request by remember { mutableStateOf<Job?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    fun release(draft: PendingDropbox) {
        val saved = existing
        container.scope.launch {
            try {
                val isExisting = saved != null && saved.host == draft.appKey && saved.username == draft.account &&
                    withContext(Dispatchers.IO) { saved.config(container.secrets).password == draft.refresh }
                if (!isExisting) draft.access.run({}) { draft.client.revokeAttempt(it) }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { /* Never carry an abandoned grant into a source. */ }
        }
    }

    fun abandon() {
        pending?.let(::release)
        pending = null
        stack = emptyList()
        folders = emptyList()
        code = ""
    }

    DisposableEffect(Unit) { onDispose { pending?.let(::release) } }
    LaunchedEffect(session) {
        if (!session.admin) {
            request?.cancel()
            abandon()
        }
    }
    LaunchedEffect(sourceId) {
        if (sourceId == null) return@LaunchedEffect
        val source = container.database.sources().get(sourceId)?.takeIf { it.sourceType == DROPBOX }
        if (source == null) { close(); return@LaunchedEffect }
        existing = source
        sourceConfig = withContext(Dispatchers.IO) { runCatching { source.config(container.secrets) }.getOrNull() }
        appKey = source.host
        name = source.name
        excludesDirectories = source.ignoredFolders
        excludesFiles = source.ignoredFiles
        loaded = true
    }

    if (!session.admin) {
        // Opening the external browser locks an enabled household. The local PKCE challenge
        // can survive while Admin unlocks again, but received credentials never do.
        FamilyGate(adminOnly = true) {}
        return
    }
    if (!loaded) return

    val authorizedSession = session
    fun authorize() {
        family.requireAdmin()
        check(family.isCurrent(authorizedSession)) { "Unlock Admin again to finish this change." }
    }

    fun submit(work: suspend () -> Unit) {
        if (busy) return
        busy = true
        error = null
        request = scope.launch {
            try { authorize(); work() }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: CloudClientException) { error = failure.message }
            catch (failure: IllegalArgumentException) { error = failure.message }
            catch (failure: IllegalStateException) { error = failure.message }
            catch (_: Exception) { error = "Could not complete the Dropbox request." }
            finally { busy = false }
        }
    }

    suspend fun list(draft: PendingDropbox, parent: String): List<DropboxFolder> = draft.access.run(::authorize) { token ->
        val entries = mutableListOf<DropboxFolder>()
        draft.client.listFolder(if (parent.isEmpty()) "" else "/$parent", token, ::authorize) { page ->
            for (entry in page) {
                val path = DropboxPath.child(entry, parent) ?: continue
                val id = entry.id ?: continue
                if (entry.kind == "folder" && DropboxClient.validId(id)) entries += DropboxFolder(id, path)
            }
            if (entries.size > 10_000) throw CloudClientException("This Dropbox folder contains too many subfolders.")
        }
        entries.distinctBy { it.id }.sortedBy { it.name.lowercase(Locale.ROOT) }
    }

    suspend fun verify(draft: PendingDropbox, folder: DropboxFolder) {
        val selected = draft.access.run(::authorize) { draft.client.metadata("/${folder.path}", it) }
        if (selected.kind != "folder" || selected.id != folder.id || !selected.displayPath.equals("/${folder.path}", ignoreCase = true)) {
            throw CloudClientException("This Dropbox folder moved. Select the folder again.")
        }
    }

    suspend fun save(source: SourceEntity) {
        val saved = existing
        container.database.withTransaction {
            authorize()
            val current = container.database.sources().get(draftId)
            check(current?.copy(lastScanAt = saved?.lastScanAt) == saved) { "The source changed. Open it again." }
            container.database.sources().upsert(source.copy(lastScanAt = current?.lastScanAt))
        }
    }

    suspend fun revokeGrant(config: SourceConfig?): Boolean {
        if (config == null) return false
        return try {
            val client = DropboxClient(config.host)
            val refreshed = client.refresh(config.password)
            client.revokeAttempt(refreshed.accessToken)
            true
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: CloudClientException) { failure.statusCode in listOf(400, 401) }
    }

    suspend fun reconnectOrAdd(draft: PendingDropbox, folder: DropboxFolder) {
        verify(draft, folder)
        val encrypted = withContext(Dispatchers.IO) { container.secrets.encrypt(draft.refresh) }
        val saved = existing
        val entity = saved?.copy(encryptedPassword = encrypted) ?: SourceEntity(
            id = draftId, name = name.trim().ifEmpty { folder.name }, host = draft.appKey, share = folder.id,
            rootPath = folder.path, username = draft.account, encryptedPassword = encrypted, sourceType = DROPBOX,
        )
        save(entity)
        pending = null
        val changedGrant = sourceConfig?.takeIf { it.password != draft.refresh }
        existing = entity
        container.scope.launch {
            container.smb.reset(entity.id)
            container.photos.resetSource(entity.id)
            container.scanner.scan(entity.id)
        }
        if (changedGrant != null) container.scope.launch { revokeGrant(changedGrant) }
        close()
    }

    fun startApproval() = submit {
        appKey = appKey.trim()
        approval = DropboxClient(appKey).beginAuthorization()
        code = ""
    }

    fun finishApproval(challenge: DropboxClient.Approval) = submit {
        val client = DropboxClient(appKey)
        val entered = code
        code = ""
        val result = client.completeAuthorization(challenge, entered)
        approval = null
        val refresh = result.refreshToken
        val account = result.accountId
        if (refresh.isNullOrBlank() || account.isNullOrBlank() || result.accessToken.isBlank() || result.expiresIn <= 0) {
            container.scope.launch { runCatching { client.revokeAttempt(result.accessToken) } }
            throw CloudClientException("Dropbox did not grant offline access. Start authorization again.")
        }
        val draft = PendingDropbox(appKey, client, result, refresh, account)
        try {
            authorize()
            val saved = existing
            if (saved == null) {
                folders = list(draft, "")
                pending = draft
            } else {
                if (saved.username != draft.account) {
                    throw CloudClientException("Reconnect with the original Dropbox account.")
                }
                reconnectOrAdd(draft, DropboxFolder(saved.share, saved.rootPath))
            }
        } catch (failure: Exception) {
            release(draft)
            throw failure
        }
    }

    fun signOut(source: SourceEntity) = submit {
        val config = runCatching { withContext(Dispatchers.IO) { source.config(container.secrets) } }
            .onFailure { if (it is CancellationException) throw it }.getOrNull()
        container.database.withTransaction {
            authorize()
            val current = container.database.sources().get(source.id)
            check(current?.copy(lastScanAt = source.lastScanAt) == source) { "The source changed. Open it again." }
            container.database.sources().delete(source.id)
        }
        removed = true
        val revocation = container.scope.async {
            container.smb.reset(source.id)
            container.photos.resetSource(source.id)
            revokeGrant(config)
        }
        val revoked = revocation.await()
        if (revoked) close()
        else error = "The local source was removed. To revoke the Dropbox grant, use Connected apps in your Dropbox account."
    }

    val saved = existing
    val savedConfig = sourceConfig
    val challenge = approval
    val draft = pending
    val stage = when {
        removed -> "removed"
        draft != null -> "folders"
        challenge != null -> "approval"
        reconnecting -> "reconnect"
        else -> "settings"
    }
    key(stage) {
        LazyColumn(contentPadding = PaddingValues(ScreenPadding), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            item {
                ScreenHeader(if (sourceId == null) "Connect Dropbox" else "Dropbox Source")
                error?.let { NasStatusPanel("Dropbox", it, error = true) }
                if (busy) NasStatusPanel("Working with Dropbox", working = true)
            }
            when {
                removed -> item { Button(onClick = close) { Text("Done") } }
                draft != null -> {
                    val here = stack.lastOrNull()
                    item {
                        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            Text(here?.let { "Dropbox / ${it.path}" } ?: "Choose a Dropbox media folder")
                            if (here != null) {
                                Button(enabled = !busy, onClick = { submit { reconnectOrAdd(draft, here) } }) { Text("Use this folder") }
                                OutlinedButton(enabled = !busy, onClick = {
                                    submit {
                                        val previous = stack.dropLast(1)
                                        folders = list(draft, previous.lastOrNull()?.path.orEmpty())
                                        stack = previous
                                    }
                                }) { Text("Up one folder") }
                            }
                            if (folders.isEmpty()) Text("No subfolders.")
                        }
                    }
                    items(folders, key = { it.id }) { folder ->
                        OutlinedButton(enabled = !busy, onClick = {
                            submit {
                                folders = list(draft, folder.path)
                                stack = stack + folder
                            }
                        }) { Text(folder.name) }
                    }
                    item { OutlinedButton(enabled = !busy, onClick = ::abandon) { Text("Use another account") } }
                }
                challenge != null -> {
                    item {
                        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            val url = challenge.url.toString()
                            val image = remember(url) { approvalQr(url) }
                            Text("Scan the QR code with your phone. In Dropbox, sign in and copy the one-time code.")
                            Image(image, "Open Dropbox approval on a phone", modifier = Modifier.size(240.dp))
                            if (!LocalTvLayout.current) OutlinedButton(enabled = !busy, onClick = {
                                try { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
                                catch (_: ActivityNotFoundException) {
                                    error = "This phone has no browser. Scan the QR code with another device."
                                }
                            }) { Text("Open Dropbox in a browser") }
                            TvTextField(code, { code = it }, "Dropbox one-time code", Modifier.fillMaxWidth(),
                                isPassword = true, enabled = !busy)
                            Button(enabled = !busy && code.isNotBlank(), onClick = { finishApproval(challenge) }) {
                                Text(if (saved == null) "Verify code and choose a folder" else "Verify code and reconnect")
                            }
                            OutlinedButton(enabled = !busy, onClick = { approval = null; code = ""; error = null }) {
                                Text("Start a new approval")
                            }
                        }
                    }
                }
                reconnecting -> {
                    item {
                        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            if (saved == null) {
                                Text("Use the public app key from a Dropbox API app with metadata and content read permissions.")
                                TvTextField(appKey, { appKey = it }, "Dropbox app key", Modifier.fillMaxWidth(), enabled = !busy)
                                TvTextField(name, { name = it }, "Source name (optional)", Modifier.fillMaxWidth(), enabled = !busy)
                            } else Text("Dropbox / ${saved.rootPath}")
                            Button(enabled = !busy && appKey.isNotBlank(), onClick = ::startApproval) { Text("Get Dropbox approval") }
                        }
                    }
                }
                saved != null -> {
                    item {
                        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            Text("Dropbox / ${saved.rootPath}")
                            if (savedConfig == null) Text("Reconnect Dropbox to restore access to this folder.")
                            TvTextField(name, { name = it }, "Source name", Modifier.fillMaxWidth(), enabled = !busy)
                            OutlinedButton(enabled = !busy, onClick = { reconnecting = true }) { Text("Reconnect Dropbox") }
                        }
                    }
                    if (savedConfig != null) item {
                        IgnoredFoldersEditor(savedConfig, excludesDirectories, excludesFiles,
                            { excludesDirectories = it }, { excludesFiles = it }, enabled = !busy)
                    }
                    item {
                        AdaptiveActions {
                            Button(enabled = !busy && name.isNotBlank(), onClick = {
                                submit {
                                    save(saved.copy(name = name.trim(), ignoredFolders = excludesDirectories, ignoredFiles = excludesFiles))
                                    container.smb.reset(saved.id)
                                    container.photos.resetSource(saved.id)
                                    close()
                                }
                            }) { Text("Save changes") }
                            if (confirmingRemoval) {
                                Text("Remove this source and its local library from MediaVault?")
                                OutlinedButton(enabled = !busy, onClick = { signOut(saved) }) { Text("Confirm sign out and remove") }
                            } else {
                                OutlinedButton(enabled = !busy, onClick = { confirmingRemoval = true }) { Text("Sign out and remove source") }
                            }
                        }
                    }
                }
            }
            if (!removed) item {
                OutlinedButton(enabled = !busy, onClick = close) { Text("Cancel") }
            }
        }
    }
}

private fun approvalQr(url: String): androidx.compose.ui.graphics.ImageBitmap {
    val pixels = 420
    val bits = QRCodeWriter().encode(url, BarcodeFormat.QR_CODE, pixels, pixels)
    val colors = IntArray(pixels * pixels) { index ->
        if (bits[index % pixels, index / pixels]) Color.BLACK else Color.WHITE
    }
    return Bitmap.createBitmap(colors, pixels, pixels, Bitmap.Config.ARGB_8888).asImageBitmap()
}
