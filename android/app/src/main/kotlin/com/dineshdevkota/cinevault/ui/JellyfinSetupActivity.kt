@file:OptIn(ExperimentalTvMaterial3Api::class)

package com.dineshdevkota.cinevault.ui

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableLongStateOf
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
import com.dineshdevkota.cinevault.jellyfin.JELLYFIN
import com.dineshdevkota.cinevault.jellyfin.JellyfinClient
import com.dineshdevkota.cinevault.jellyfin.JellyfinConnection
import com.dineshdevkota.cinevault.jellyfin.JellyfinException
import com.dineshdevkota.cinevault.jellyfin.JellyfinItem
import com.dineshdevkota.cinevault.jellyfin.JellyfinSession
import com.dineshdevkota.cinevault.jellyfin.JellyfinSetupSessions
import com.dineshdevkota.cinevault.jellyfin.jellyfinConnection
import com.dineshdevkota.cinevault.jellyfin.jellyfinEndpoint
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.util.UUID

internal class JellyfinSetupActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!container.family.current.admin) { finish(); return }
        setCineVaultContent { JellyfinSetup(intent.getStringExtra("source_id"), ::finish) }
    }

    companion object {
        fun start(context: Context, sourceId: String? = null) {
            context.startActivity(Intent(context, JellyfinSetupActivity::class.java).putExtra("source_id", sourceId))
        }
    }
}

@Composable
private fun JellyfinSetup(sourceId: String?, close: () -> Unit) {
    val container = LocalContext.current.container
    val family = container.family
    val session = family.session.collectAsStateWithLifecycle().value
    val scope = rememberCoroutineScope()
    val draft = remember(sourceId) { sourceId ?: UUID.randomUUID().toString() }
    var existing by remember { mutableStateOf<SourceEntity?>(null) }
    var loaded by remember { mutableStateOf(sourceId == null) }
    var endpoint by remember { mutableStateOf("") }
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var name by remember { mutableStateOf("") }
    var connection by remember { mutableStateOf<JellyfinSetupSessions.Draft?>(null) }
    var libraries by remember { mutableStateOf(emptyList<JellyfinItem>()) }
    var busy by remember { mutableStateOf(false) }
    var quickCode by remember { mutableStateOf<String?>(null) }
    var request by remember { mutableStateOf<Job?>(null) }
    var requestEpoch by remember { mutableLongStateOf(0L) }
    var confirmingRemoval by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(session) { if (!session.admin) close() }
    LaunchedEffect(sourceId) {
        if (sourceId == null) return@LaunchedEffect
        val saved = container.database.sources().get(sourceId)?.takeIf { it.sourceType == JELLYFIN }
        if (saved == null) { close(); return@LaunchedEffect }
        existing = saved
        endpoint = saved.host
        name = saved.name
        loaded = true
    }
    DisposableEffect(Unit) {
        onDispose { connection?.abandon() }
    }
    if (!session.admin || !loaded) return
    fun authorize() {
        family.requireAdmin()
        check(family.isCurrent(session)) { "Unlock Admin again to finish this change." }
    }

    fun authorizeRequest(epoch: Long) {
        if (epoch != requestEpoch) throw CancellationException("The Jellyfin setup request ended.")
        authorize()
    }

    fun submit(work: suspend (Long) -> Unit) {
        if (busy) return
        busy = true
        error = null
        val epoch = ++requestEpoch
        request = scope.launch {
            try {
                authorizeRequest(epoch)
                work(epoch)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                if (epoch == requestEpoch) error = when (failure) {
                    is JellyfinException -> failure.message
                    is IllegalArgumentException, is IllegalStateException -> failure.message
                    else -> "Unable to reach Jellyfin. Check your server, address, and HTTPS certificate."
                }
            } finally {
                if (epoch == requestEpoch) {
                    busy = false
                    quickCode = null
                    request = null
                }
            }
        }
    }

    fun cancelQuickConnect() {
        requestEpoch++
        request?.cancel()
        request = null
        busy = false
        quickCode = null
    }

    suspend fun signInAndChooseLibrary(
        client: JellyfinClient, address: String, epoch: Long, authenticate: suspend () -> JellyfinSession,
    ) {
        val saved = existing
        val original = withContext(Dispatchers.IO) {
            runCatching { saved?.let { container.secrets.decrypt(it.encryptedPassword) } }
        }
        val issued = container.jellyfinSetupSessions.open(
            address, original,
            savedToken = { token ->
                val current = container.database.sources().get(draft)
                current?.sourceType == JELLYFIN && current.host == address &&
                    withContext(Dispatchers.IO) { container.secrets.decrypt(current.encryptedPassword) == token }
            },
            authorize = { authorizeRequest(epoch) },
            authenticate = { JellyfinConnection(client, authenticate()) },
        )
        val choices = issued.prepare { authenticated ->
            val signedIn = authenticated.session
            if (saved != null && signedIn.user.id != saved.username) {
                throw JellyfinException("Reconnect with the original Jellyfin account, or add a new source.")
            }
            val available = authenticated.client.libraries(signedIn).filter {
                it.collectionType in setOf(null, "movies", "tvshows", "mixed", "homevideos")
            }.distinctBy { it.id }.filter { it.id.isNotBlank() }
            val choices = if (saved == null) available else available.filter { it.id == saved.share }
            if (choices.isEmpty()) throw JellyfinException(
                if (saved == null) "This account has no accessible movie, TV or photo libraries."
                else "This account no longer has access to the saved Jellyfin library.")
            authorizeRequest(epoch)
            choices
        }
        libraries = choices
        connection = issued
    }

    BackHandler(enabled = quickCode != null) { cancelQuickConnect() }
    // Login and library selection have different focusable lists. Status updates
    // stay inside the header row within each stage.
    key(connection != null) {
        LazyColumn(contentPadding = PaddingValues(ScreenPadding), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            item {
                Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    ScreenHeader(if (sourceId == null) "Connect Jellyfin" else "Edit Jellyfin Source", kicker = "SOURCES")
                    error?.let { NasStatusPanel("Could not complete the Jellyfin request", it, error = true) }
                    if (busy) {
                        val code = quickCode
                        if (code == null) NasStatusPanel("Connecting to Jellyfin", working = true)
                        else {
                            NasStatusPanel("Quick Connect code: $code",
                                "Approve this code in your signed-in Jellyfin app to continue.", working = true)
                            OutlinedButton(onClick = { cancelQuickConnect() }) { Text("Cancel Quick Connect") }
                        }
                    }
                }
            }
            item { TvTextField(name, { name = it }, "Source name (optional)", Modifier.fillMaxWidth(), enabled = !busy) }
            item {
                TvTextField(endpoint, { endpoint = it }, "Jellyfin HTTPS address",
                    Modifier.fillMaxWidth(), enabled = !busy && existing == null && connection == null)
            }
            if (connection == null) {
                item { TvTextField(username, { username = it }, "Jellyfin username", Modifier.fillMaxWidth(), enabled = !busy) }
                item { TvTextField(password, { password = it }, "Jellyfin password", Modifier.fillMaxWidth(), isPassword = true, enabled = !busy) }
                item {
                    Button(enabled = !busy && endpoint.isNotBlank() && username.isNotBlank(), onClick = {
                        submit { epoch ->
                            val address = jellyfinEndpoint(endpoint)
                            val client = JellyfinClient(address, draft, BuildConfig.VERSION_NAME)
                            val enteredUsername = username.trim()
                            val enteredPassword = password
                            password = ""
                            signInAndChooseLibrary(client, address, epoch) { client.signIn(enteredUsername, enteredPassword) }
                        }
                    }) { Text(if (existing == null) "Sign in and choose a library" else "Reconnect") }
                }
                item {
                    OutlinedButton(enabled = !busy && endpoint.isNotBlank(), onClick = {
                        submit { epoch ->
                            val address = jellyfinEndpoint(endpoint)
                            val client = JellyfinClient(address, draft, BuildConfig.VERSION_NAME)
                            val challenge = client.beginQuickConnect()
                            authorizeRequest(epoch)
                            if (challenge.code.length != 6 || !challenge.code.all { it in '0'..'9' }) {
                                throw JellyfinException("Jellyfin returned an invalid Quick Connect code.")
                            }
                            quickCode = challenge.code
                            withTimeoutOrNull(5 * 60 * 1000L) {
                                var accepted = challenge.authenticated
                                while (!accepted) {
                                    delay(2_000)
                                    authorizeRequest(epoch)
                                    accepted = client.pollQuickConnect(challenge.secret).authenticated
                                }
                            } ?: throw JellyfinException("The Quick Connect code expired. Request a new one.")
                            signInAndChooseLibrary(client, address, epoch) { client.finishQuickConnect(challenge.secret) }
                        }
                    }) { Text("Use Quick Connect") }
                }
            } else {
                item { Text("Choose a library to import. Add another source to connect a different library.") }
                items(libraries, key = { it.id }) { library ->
                    Button(enabled = !busy, onClick = {
                        submit { epoch ->
                            val issued = checkNotNull(connection)
                            val signedIn = issued.connection.session
                            val saved = existing
                            val encrypted = withContext(Dispatchers.IO) { container.secrets.encrypt(signedIn.token) }
                            val source = SourceEntity(
                                id = draft, name = name.trim().ifEmpty { library.name },
                                host = issued.endpoint, share = library.id, username = signedIn.user.id,
                                encryptedPassword = encrypted, sourceType = JELLYFIN, lastScanAt = saved?.lastScanAt,
                            )
                            issued.save {
                                container.database.withTransaction {
                                    authorizeRequest(epoch)
                                    val current = container.database.sources().get(draft)
                                    check(current?.copy(lastScanAt = saved?.lastScanAt) == saved) { "The source changed. Open it again." }
                                    container.database.sources().upsert(source.copy(lastScanAt = current?.lastScanAt))
                                }
                            }
                            container.scope.launch { container.scanner.scan(draft) }
                            close()
                        }
                    }) { Text(library.name) }
                }
                item {
                    OutlinedButton(enabled = !busy, onClick = {
                        connection?.abandon()
                        connection = null
                        libraries = emptyList()
                    }) { Text("Back to sign in") }
                }
            }
            val savedSource = existing
            if (savedSource != null) {
                item {
                    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                        OutlinedButton(enabled = !busy && name.isNotBlank() && name.trim() != savedSource.name,
                            onClick = {
                                submit {
                                    container.database.withTransaction {
                                        authorize()
                                        val current = container.database.sources().get(draft)
                                        check(current?.copy(lastScanAt = savedSource.lastScanAt) == savedSource) {
                                            "The source changed. Open it again."
                                        }
                                        container.database.sources().upsert(checkNotNull(current).copy(name = name.trim()))
                                    }
                                    close()
                                }
                            },
                        ) { Text("Save source name") }
                        OutlinedButton(enabled = !busy, onClick = {
                            if (!confirmingRemoval) { confirmingRemoval = true; return@OutlinedButton }
                            submit {
                                val saved = checkNotNull(existing)
                                container.database.withTransaction {
                                    authorize()
                                    val current = container.database.sources().get(saved.id)
                                    check(current?.copy(lastScanAt = saved.lastScanAt) == saved) { "The source changed. Open it again." }
                                    container.database.sources().delete(saved.id)
                                }
                                // Local removal succeeds even if the server is unavailable or already signed out.
                                container.scope.launch(Dispatchers.IO) {
                                    runCatching { saved.jellyfinConnection(container.secrets) }.getOrNull()?.let {
                                        try { it.client.signOut(it.session) }
                                        catch (cancelled: CancellationException) { throw cancelled }
                                        catch (_: Exception) { }
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
