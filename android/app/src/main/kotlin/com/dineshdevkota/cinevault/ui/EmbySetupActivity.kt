@file:OptIn(ExperimentalTvMaterial3Api::class)

package com.dineshdevkota.cinevault.ui

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.room.withTransaction
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.Text
import com.dineshdevkota.cinevault.BuildConfig
import com.dineshdevkota.cinevault.container
import com.dineshdevkota.cinevault.data.SourceEntity
import com.dineshdevkota.cinevault.emby.EMBY
import com.dineshdevkota.cinevault.emby.EmbyClient
import com.dineshdevkota.cinevault.emby.EmbyConnection
import com.dineshdevkota.cinevault.emby.EmbyException
import com.dineshdevkota.cinevault.emby.embyConnection
import com.dineshdevkota.cinevault.emby.embyEndpoint
import com.dineshdevkota.cinevault.emby.validEmbyIdentifier
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.UUID

internal class EmbySetupActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!container.family.current.admin) {
            finish()
            return
        }
        setCineVaultContent { EmbySetup(intent.getStringExtra("source_id"), ::finish) }
    }

    companion object {
        fun start(context: Context, sourceId: String? = null) {
            context.startActivity(Intent(context, EmbySetupActivity::class.java).putExtra("source_id", sourceId))
        }
    }
}

@Composable
private fun EmbySetup(sourceId: String?, close: () -> Unit) {
    val container = LocalContext.current.container
    val family = container.family
    val active = family.session.collectAsStateWithLifecycle().value
    val scope = rememberCoroutineScope()
    val draft = remember(sourceId) { sourceId ?: UUID.randomUUID().toString() }
    var existing by remember { mutableStateOf<SourceEntity?>(null) }
    var ready by remember { mutableStateOf(sourceId == null) }
    var endpoint by remember { mutableStateOf("") }
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var name by remember { mutableStateOf("") }
    var connection by remember { mutableStateOf<EmbyConnection?>(null) }
    var libraries by remember { mutableStateOf(emptyList<EmbyClient.Item>()) }
    var busy by remember { mutableStateOf(false) }
    var confirmingRemoval by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(active) { if (!active.admin) close() }
    LaunchedEffect(sourceId) {
        if (sourceId == null) return@LaunchedEffect
        val saved = container.database.sources().get(sourceId)?.takeIf { it.sourceType == EMBY }
        if (saved == null) {
            close()
            return@LaunchedEffect
        }
        existing = saved
        endpoint = saved.host
        name = saved.name
        ready = true
    }
    if (!active.admin || !ready) return

    fun authorize() {
        family.requireAdmin()
        check(family.isCurrent(active)) { "Unlock Admin again to finish this change." }
    }

    fun submit(work: suspend () -> Unit) {
        if (busy) return
        busy = true
        error = null
        scope.launch {
            try {
                authorize()
                work()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                error = when {
                    failure is EmbyException && failure.status == 401 -> "Emby rejected those credentials. Try signing in again."
                    failure is EmbyException && failure.status == 403 -> "This Emby account cannot access the requested library."
                    failure is EmbyException -> failure.message
                    else -> "Unable to finish the Emby request. Check the HTTPS address and try again."
                }
            } finally {
                busy = false
            }
        }
    }

    key(connection != null) {
        LazyColumn(contentPadding = PaddingValues(ScreenPadding), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            item {
                Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    ScreenHeader(if (sourceId == null) "Connect Emby" else "Edit Emby Source", kicker = "SOURCES")
                    if (busy) NasStatusPanel("Contacting Emby", working = true)
                    error?.let { NasStatusPanel("Could not complete the Emby request", it, error = true) }
                }
            }
            item { TvTextField(name, { name = it }, "Source name (optional)", Modifier.fillMaxWidth(), enabled = !busy) }
            item {
                TvTextField(endpoint, { endpoint = it }, "Emby HTTPS address (include /emby if required)",
                    Modifier.fillMaxWidth(), enabled = !busy && existing == null && connection == null)
            }
            if (connection == null) {
                item { TvTextField(username, { username = it }, "Emby username", Modifier.fillMaxWidth(), enabled = !busy) }
                item { TvTextField(password, { password = it }, "Emby password", Modifier.fillMaxWidth(), enabled = !busy, isPassword = true) }
                item {
                    Button(enabled = !busy && endpoint.isNotBlank() && username.isNotBlank(), onClick = {
                        submit {
                            val address = try { embyEndpoint(endpoint) }
                            catch (failure: IllegalArgumentException) { throw EmbyException(failure.message.orEmpty()) }
                            val client = EmbyClient(address, draft, BuildConfig.VERSION_NAME)
                            val entered = password
                            password = ""
                            val account = client.signIn(username.trim(), entered)
                            authorize()
                            val saved = existing
                            if (saved != null && account.User.Id != saved.username) {
                                throw EmbyException("Reconnect with the original Emby account, or add a separate source.")
                            }
                            val choices = client.libraries(account)
                                .filter { validEmbyIdentifier(it.Id) && it.Name.isNotBlank() }
                                .filter { it.CollectionType in setOf(null, "", "movies", "tvshows", "mixed", "homevideos") }
                                .distinctBy { it.Id }
                            libraries = if (saved == null) choices else choices.filter { it.Id == saved.share }
                            if (libraries.isEmpty()) throw EmbyException("This account has no accessible movie or TV libraries for this source.")
                            authorize()
                            endpoint = address
                            connection = EmbyConnection(client, account)
                        }
                    }) { Text(if (existing == null) "Sign in and choose a library" else "Reconnect Emby") }
                }
            } else {
                item { Text("Choose a movie or TV library. Add another source to import a different library.") }
                items(libraries, key = { it.Id }) { library ->
                    Button(enabled = !busy, onClick = {
                        submit {
                            val signedIn = checkNotNull(connection).account
                            val saved = existing
                            val encrypted = withContext(Dispatchers.IO) { container.secrets.encrypt(signedIn.AccessToken) }
                            val source = SourceEntity(
                                id = draft, name = name.trim().ifEmpty { library.Name },
                                host = endpoint, share = library.Id, username = signedIn.User.Id,
                                encryptedPassword = encrypted, sourceType = EMBY, lastScanAt = saved?.lastScanAt,
                            )
                            container.database.withTransaction {
                                authorize()
                                val current = container.database.sources().get(draft)
                                check(current?.copy(lastScanAt = saved?.lastScanAt) == saved) { "The source changed. Open it again." }
                                container.database.sources().upsert(source.copy(lastScanAt = current?.lastScanAt))
                            }
                            container.scope.launch { container.scanner.scan(draft) }
                            close()
                        }
                    }) { Text(library.Name) }
                }
                item {
                    OutlinedButton(enabled = !busy, onClick = {
                        connection = null
                        libraries = emptyList()
                    }) { Text("Back to sign in") }
                }
            }
            val saved = existing
            if (saved != null) {
                item {
                    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                        OutlinedButton(enabled = !busy && name.isNotBlank() && name.trim() != saved.name, onClick = {
                            submit {
                                container.database.withTransaction {
                                    authorize()
                                    val current = container.database.sources().get(draft)
                                    check(current?.copy(lastScanAt = saved.lastScanAt) == saved) { "The source changed. Open it again." }
                                    container.database.sources().upsert(checkNotNull(current).copy(name = name.trim()))
                                }
                                close()
                            }
                        }) { Text("Save source name") }
                        OutlinedButton(enabled = !busy, onClick = {
                            if (!confirmingRemoval) {
                                confirmingRemoval = true
                                return@OutlinedButton
                            }
                            submit {
                                container.database.withTransaction {
                                    authorize()
                                    val current = container.database.sources().get(saved.id)
                                    check(current?.copy(lastScanAt = saved.lastScanAt) == saved) { "The source changed. Open it again." }
                                    container.database.sources().delete(saved.id)
                                }
                                container.scope.launch(Dispatchers.IO) {
                                    try {
                                        val remote = saved.embyConnection(container.secrets)
                                        remote.client.signOut(remote.account)
                                    } catch (cancelled: CancellationException) {
                                        throw cancelled
                                    } catch (_: Exception) {
                                        // Local removal is still complete when Emby is offline.
                                    }
                                }
                                close()
                            }
                        }) { Text(if (confirmingRemoval) "Confirm sign out and remove library" else "Sign out and remove source") }
                    }
                }
            }
            item { OutlinedButton(onClick = close, enabled = !busy) { Text("Cancel") } }
        }
    }
}
