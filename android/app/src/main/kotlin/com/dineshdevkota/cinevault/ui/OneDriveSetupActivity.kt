package com.dineshdevkota.cinevault.ui

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.room.withTransaction
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import com.dineshdevkota.cinevault.BuildConfig
import com.dineshdevkota.cinevault.cloud.CloudClientException
import com.dineshdevkota.cinevault.cloud.ONEDRIVE
import com.dineshdevkota.cinevault.cloud.OneDriveAccount
import com.dineshdevkota.cinevault.cloud.OneDriveClient
import com.dineshdevkota.cinevault.container
import com.dineshdevkota.cinevault.data.SourceEntity
import com.dineshdevkota.cinevault.data.saveSourceWithExclusions
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class OneDriveSetupActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val sourceId = intent.getStringExtra(SOURCE_ID)
        setCineVaultContent { OneDriveSetup(sourceId, ::finish) }
    }

    companion object {
        private const val SOURCE_ID = "source_id"

        fun start(context: Context, sourceId: String? = null) {
            context.startActivity(Intent(context, OneDriveSetupActivity::class.java).putExtra(SOURCE_ID, sourceId))
        }
    }
}

private data class OneDriveFolder(val id: String?, val name: String)
private class OneDriveLink(val account: OneDriveAccount, val version: Long, val applicationId: String)

@Composable
private fun OneDriveSetup(sourceId: String?, close: () -> Unit) {
    val context = LocalContext.current
    val app = context.container
    val family = app.family
    val scope = rememberCoroutineScope()
    val draftId = rememberSaveable { UUID.randomUUID().toString() }
    val sourceUUID = remember(sourceId, draftId) { UUID.fromString(sourceId ?: draftId) }
    var loaded by remember { mutableStateOf(sourceId == null) }
    var current by remember { mutableStateOf<SourceEntity?>(null) }
    var applicationId by rememberSaveable { mutableStateOf(BuildConfig.ONEDRIVE_CLIENT_ID) }
    var name by rememberSaveable { mutableStateOf("") }
    var ignoredFolders by remember { mutableStateOf<List<String>>(emptyList()) }
    var ignoredFiles by remember { mutableStateOf<List<String>>(emptyList()) }
    var challenge by remember { mutableStateOf<OneDriveClient.Challenge?>(null) }
    var linked by remember { mutableStateOf<OneDriveLink?>(null) }
    var folders by remember { mutableStateOf<List<OneDriveClient.Entry>>(emptyList()) }
    var path by remember { mutableStateOf(listOf(OneDriveFolder(null, "OneDrive"))) }
    var busy by remember { mutableStateOf<String?>(null) }
    var committing by remember { mutableStateOf(false) }
    var operation by remember { mutableStateOf<Job?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var status by remember { mutableStateOf<String?>(null) }
    var confirmDisconnect by remember { mutableStateOf(false) }
    val screenSession = remember { family.current }
    val isTv = LocalTvLayout.current

    fun authorize() {
        check(family.isCurrent(screenSession) && screenSession.admin) { "Return to Admin and open this source again." }
    }

    DisposableEffect(sourceUUID) {
        onDispose {
            operation?.cancel()
            if (sourceId == null && current == null) app.scope.launch { app.oneDrive.discardDraft(sourceUUID) }
        }
    }

    LaunchedEffect(sourceId) {
        if (sourceId != null) {
            authorize()
            current = app.database.sources().get(sourceId)?.takeIf { it.sourceType == ONEDRIVE }
            current?.let { source ->
                name = source.name
                applicationId = source.host
                ignoredFolders = source.ignoredFolders
                ignoredFiles = source.ignoredFiles
            }
            loaded = true
        }
    }

    fun perform(label: String, action: suspend () -> Unit) {
        if (busy != null) return
        busy = label
        error = null
        status = null
        operation = scope.launch {
            try {
                authorize()
                action()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                error = when (failure) {
                    is CloudClientException, is IllegalStateException -> failure.message
                    is IllegalArgumentException -> "Enter the public application ID from your Microsoft Entra registration."
                    else -> "Could not contact OneDrive. Check your connection and try again."
                }
            } finally {
                busy = null
                committing = false
                challenge = null
            }
        }
    }

    fun navigate(to: List<OneDriveFolder>) {
        val signIn = linked ?: return
        perform("Reading OneDrive folders…") {
            val children = app.oneDrive.childFolders(signIn.account, to.last().id, signIn.version)
            authorize()
            folders = children
            path = to
        }
    }

    fun connect() = perform("Starting Microsoft sign-in…") {
        val clientID = applicationId.trim()
        if (sourceId == null) app.oneDrive.discardDraft(sourceUUID)
        val account = app.oneDrive.account(sourceUUID, clientID)
        try {
            val code = account.beginSignIn()
            authorize()
            challenge = code
            account.link(code, staged = true)
            val version = account.connectionVersion()
            authorize()
            val existing = current
            if (existing == null) {
                folders = app.oneDrive.childFolders(account, null, version)
                authorize()
                path = listOf(OneDriveFolder(null, "OneDrive"))
                linked = OneDriveLink(account, version, clientID)
            } else {
                account.list(existing.share.ifBlank { null }, version) { authorize() }
                authorize()
                account.commitLink(version)
                status = "OneDrive reconnected."
                app.photos.clearMemory()
                app.scope.launch { app.scanner.scan(existing.id) }
            }
        } catch (failure: Exception) {
            withContext(NonCancellable) { account.cancelLink() }
            throw failure
        }
    }

    fun back() {
        if (committing) return
        if (busy != null) operation?.cancel()
        else if (linked != null && path.size > 1) navigate(path.dropLast(1))
        else close()
    }
    BackHandler { back() }

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = ScreenPadding, vertical = 20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item { ScreenHeader(if (sourceId == null) "Connect OneDrive" else "Edit OneDrive Source", showBack = false) }
        item { OutlinedButton(onClick = ::back, enabled = !committing) { Text(if (busy == null) "Back" else "Cancel") } }
        error?.let { item { NasStatusPanel("OneDrive needs attention", it, error = true) } }
        status?.let { item { NasStatusPanel(it) } }
        val code = challenge
        if (code != null) {
            item {
                Text("Enter this code at ${code.verificationUri.host}${code.verificationUri.encodedPath}",
                    style = MaterialTheme.typography.titleMedium)
                Text(code.userCode, style = MaterialTheme.typography.displaySmall, color = Accent)
                Text("Complete Microsoft sign-in in a browser. Leave this screen open while MediaVault waits.")
                if (screenSession.enabled) Text("Use a browser on another device so the Admin session stays unlocked.", color = SecondaryText)
            }
            if (!isTv && !screenSession.enabled) {
                item { OutlinedButton(onClick = {
                    try { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(code.verificationUri.toString()))) }
                    catch (_: ActivityNotFoundException) { error = "Open the sign-in address in another browser." }
                }) { Text("Open Microsoft sign-in") } }
            }
        } else if (busy != null) item { NasStatusPanel(busy.orEmpty(), working = true) }

        if (!loaded) {
            item { NasStatusPanel("Opening OneDrive source…", working = true) }
        } else if (sourceId != null && current == null) {
            item { Text("This OneDrive source is no longer available.", color = ErrorText) }
        } else if (linked != null) {
            item {
                Text(path.joinToString(" / ") { it.name }, style = MaterialTheme.typography.titleLarge)
                TvTextField(name, { name = it }, "Source name (optional)", Modifier.fillMaxWidth(), enabled = busy == null)
            }
            if (path.size > 1) item {
                OutlinedButton(onClick = { navigate(path.dropLast(1)) }, enabled = busy == null) { Text("Up one folder") }
            }
            item {
                Button(enabled = busy == null, onClick = {
                    val signIn = linked ?: return@Button
                    val selected = path.last()
                    val source = SourceEntity(
                        id = sourceUUID.toString(), name = name.trim().ifEmpty { selected.name },
                        host = signIn.applicationId, share = selected.id.orEmpty(),
                        username = path.joinToString(" / ") { it.name }, sourceType = ONEDRIVE,
                    )
                    perform("Saving OneDrive source…") {
                        authorize()
                        committing = true
                        withContext(NonCancellable) {
                            signIn.account.commitLink(signIn.version)
                            try {
                                app.database.withTransaction {
                                    authorize()
                                    check(app.database.sources().get(source.id) == null) { "This OneDrive source already exists." }
                                    app.database.sources().upsert(source)
                                }
                            } catch (failure: Exception) {
                                signIn.account.disconnect()
                                throw failure
                            }
                            current = source
                            app.scope.launch { app.scanner.scan(source.id) }
                        }
                        close()
                    }
                }) { Text("Use this folder & scan") }
            }
            items(folders, key = { it.id }) { child ->
                OutlinedButton(
                    onClick = { navigate(path + OneDriveFolder(child.id, child.name)) },
                    enabled = busy == null,
                    modifier = Modifier.fillMaxWidth(),
                ) { Text("${child.name}  ›") }
            }
            if (folders.isEmpty()) item { Text("No subfolders. You can use this folder.", color = SecondaryText) }
        } else if (current == null) {
            item { Text("Use a Microsoft Entra public client registered for personal Microsoft accounts with delegated Files.Read access.", color = SecondaryText) }
            item { TvTextField(applicationId, { applicationId = it }, "Microsoft Entra application ID",
                Modifier.fillMaxWidth(), keyboardType = KeyboardType.Ascii, enabled = busy == null) }
            item { Button(onClick = ::connect, enabled = busy == null && applicationId.isNotBlank()) { Text("Sign in with Microsoft") } }
        } else {
            val source = checkNotNull(current)
            item { Text("Folder · ${source.username}", style = MaterialTheme.typography.titleMedium) }
            item { TvTextField(name, { name = it }, "Source name", Modifier.fillMaxWidth(), enabled = busy == null) }
            item {
                val config = source.config(app.secrets)
                IgnoredFoldersEditor(config, ignoredFolders, ignoredFiles, { ignoredFolders = it }, { ignoredFiles = it },
                    enabled = busy == null) { path ->
                    authorize()
                    app.oneDrive.listEntries(config, path).also { authorize() }
                }
            }
            item {
                AdaptiveActions {
                    Button(enabled = busy == null && name.isNotBlank(), onClick = {
                        perform("Saving OneDrive source…") {
                            app.database.withTransaction {
                                authorize()
                                val latest = app.database.sources().get(source.id)
                                    ?: throw CloudClientException("This OneDrive source was removed.")
                                app.database.saveSourceWithExclusions(latest.copy(
                                    name = name.trim(), ignoredFolders = ignoredFolders, ignoredFiles = ignoredFiles,
                                ), ::authorize)
                            }
                            app.smb.reset(source.id)
                            app.photos.clearMemory()
                            app.scope.launch { app.scanner.scan(source.id) }
                            close()
                        }
                    }) { Text("Save changes & scan") }
                    OutlinedButton(onClick = ::connect, enabled = busy == null) { Text("Reconnect Microsoft account") }
                    OutlinedButton(enabled = busy == null, onClick = {
                        if (!confirmDisconnect) confirmDisconnect = true else perform("Disconnecting OneDrive…") {
                            authorize()
                            committing = true
                            withContext(NonCancellable) {
                                app.oneDrive.disconnect(sourceUUID, source.host)
                                app.photos.clearMemory()
                                app.database.sources().delete(source.id)
                            }
                            close()
                        }
                    }) { Text(if (confirmDisconnect) "Confirm disconnect and remove library" else "Disconnect OneDrive") }
                }
            }
            if (confirmDisconnect) item {
                Text("This removes the local source and its viewing history. Your OneDrive files stay in your account.", color = SecondaryText)
            }
        }
    }
}
