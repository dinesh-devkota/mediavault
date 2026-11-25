package com.dineshdevkota.cinevault.ui

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import com.dineshdevkota.cinevault.container
import com.dineshdevkota.cinevault.family.*
import com.dineshdevkota.cinevault.data.SourceEntity
import com.dineshdevkota.cinevault.jellyfin.JELLYFIN
import com.dineshdevkota.cinevault.smb.NasBrowser
import com.dineshdevkota.cinevault.smb.SmbService
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class FamilyActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setCineVaultContent { FamilySettings { finish() } }
    }
    companion object { fun start(context: Context) { context.startActivity(Intent(context, FamilyActivity::class.java)) } }
}

@Composable
fun FamilyGate(adminOnly: Boolean = false, content: @Composable () -> Unit) {
    val family = LocalContext.current.container.family
    val session by family.session.collectAsStateWithLifecycle()
    when {
        !session.unlocked -> key(session.generation) { ProfilePicker() }
        adminOnly && !session.admin -> AdminRequired()
        else -> key(session.historyId, session.enabled) { content() }
    }
}

@Composable
fun AdminRequired() {
    val family = LocalContext.current.container.family
    Column(Modifier.padding(ScreenPadding), verticalArrangement = Arrangement.spacedBy(20.dp)) {
        Text("Managed by Admin", style = MaterialTheme.typography.headlineMedium)
        Text("An adult manages NAS connections, household permissions and shared settings.", color = SecondaryText)
        Button(onClick = { family.lock() }) { Text("Switch profile") }
    }
}

@Composable
fun ProfilePicker() {
    val family = LocalContext.current.container.family
    val session by family.session.collectAsStateWithLifecycle()
    var selected by remember { mutableStateOf<HouseholdProfile?>(null) }
    val profile = selected
    if (profile != null) {
        PinPrompt("Unlock ${profile.name}", onCancel = { selected = null }) { pin, epoch -> family.unlock(profile.id, pin, epoch) }
        return
    }
    val scope = rememberCoroutineScope()
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    LazyColumn(Modifier.fillMaxSize().testTag("household-picker"), contentPadding = PaddingValues(ScreenPadding),
        verticalArrangement = Arrangement.spacedBy(20.dp)) {
        item { Text("Who's watching?", style = MaterialTheme.typography.headlineLarge) }
        item { Text("Your library and viewing progress stay with your profile on this device.", color = SecondaryText) }
        if (session.damaged) item {
            Text("Household controls could not be read. Close and reopen MediaVault to retry. Your library stays locked.", color = ErrorText)
        }
        family.profiles.forEach { entry -> item(key = entry.id) {
            Button(enabled = !busy, onClick = {
                if (entry.pin != null) selected = entry else {
                    val epoch = family.authenticationEpoch
                    busy = true
                    scope.launch {
                        try { error = family.unlock(entry.id, "", epoch) }
                        catch (cancelled: CancellationException) { throw cancelled }
                        catch (_: Exception) { error = "The profile could not be unlocked. Access remains locked." }
                        finally { busy = false }
                    }
                }
            }) { Text(entry.name + if (entry.pin != null) " · PIN required" else "") }
        } }
        error?.let { item { Text(it, color = ErrorText) } }
    }
}

@Composable
private fun PinPrompt(title: String, onCancel: () -> Unit, verify: suspend (String, Long) -> String?) {
    val family = LocalContext.current.container.family
    val promptEpoch by family.authenticationEpochs.collectAsState()
    var pin by remember(promptEpoch) { mutableStateOf("") }
    var busy by remember(promptEpoch) { mutableStateOf(false) }
    var error by remember(promptEpoch) { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    BackHandler { if (!busy) onCancel() }
    Column(Modifier.padding(ScreenPadding), verticalArrangement = Arrangement.spacedBy(20.dp)) {
        Text(title, style = MaterialTheme.typography.headlineMedium)
        PinField(pin, { pin = it }, "Six-digit PIN", enabled = !busy)
        AdaptiveActions() {
            Button(enabled = PinVerifier.valid(pin) && !busy, onClick = {
                val submitted = pin; val requestEpoch = promptEpoch; pin = ""; busy = true
                scope.launch {
                    try { error = verify(submitted, requestEpoch) }
                    catch (cancelled: CancellationException) { throw cancelled }
                    catch (_: Exception) { error = "The PIN could not be checked. Access remains locked." }
                    finally { busy = false }
                }
            }) { Text(if (busy) "Checking…" else "Unlock") }
            OutlinedButton(enabled = !busy, onClick = onCancel) { Text("Back") }
        }
        error?.let { Text(it, color = ErrorText) }
        Text("Forgotten PINs cannot be recovered inside the app.", color = SecondaryText)
    }
}

@Composable
private fun PinField(value: String, onChange: (String) -> Unit, label: String, enabled: Boolean = true) {
    TvTextField(value, { onChange(it.filter { char -> char in '0'..'9' }.take(6)) }, label,
        Modifier.width(420.dp), isPassword = true, keyboardType = KeyboardType.NumberPassword, enabled = enabled)
}

@Composable
fun HouseholdButton() {
    val context = LocalContext.current
    val family = context.container.family
    val session by family.session.collectAsStateWithLifecycle()
    AdaptiveActions() {
        OutlinedButton(onClick = { FamilyActivity.start(context) }) { Text("Household profiles") }
        if (session.enabled) OutlinedButton(onClick = { family.lock() }) { Text("Switch profile · ${session.profile?.name.orEmpty()}") }
    }
}

@Composable
private fun FamilySettings(onClose: () -> Unit) {
    val container = LocalContext.current.container
    val family = container.family
    val session by family.session.collectAsStateWithLifecycle()
    var editing by remember { mutableStateOf<HouseholdProfile?>(null) }
    var verifying by remember { mutableStateOf(false) }
    var authorized by remember { mutableStateOf(false) }
    var confirmOff by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    if (!session.enabled) {
        if (family.profiles.isEmpty()) SetupHousehold(onClose) else DisabledHousehold(onClose)
        return
    }
    if (!session.admin) { AdminRequired(); return }
    // Permission changes require a fresh Admin PIN, even when entering from an existing Admin session.
    if (verifying && !authorized) {
        PinPrompt("Confirm Admin PIN", onCancel = { verifying = false }) { pin, epoch ->
            family.unlock(HouseholdProfile.ADMIN, pin, epoch).also { if (it == null) authorized = true }
        }
        return
    }
    editing?.let { profile ->
        ProfileEditor(profile, onClose = { editing = null })
        return
    }
    LazyColumn(contentPadding = PaddingValues(ScreenPadding), verticalArrangement = Arrangement.spacedBy(20.dp)) {
        item { Text("Your household", style = MaterialTheme.typography.headlineLarge) }
        item { Text("Profiles live on this device. Admin manages media and permissions. Each viewer has a separate Watchlist and viewing history.", color = SecondaryText) }
        item { OutlinedButton(onClick = { family.lock() }) { Text("Switch profile") } }
        if (!authorized) item {
            Button(onClick = { verifying = true }) { Text("Manage profiles · Admin PIN") }
        } else {
            family.profiles.forEach { profile -> item(key = profile.id) {
                OutlinedButton(onClick = { editing = profile }) { Text(if (profile.isAdmin) "Admin · Change PIN" else "Edit ${profile.name}") }
            } }
            item { Button(onClick = { editing = family.newProfile() }) { Text("Add a viewer") } }
            item {
                Text("Turning profiles off makes the full library visible. Your profiles, permissions and viewing histories are kept for next time.", color = SecondaryText)
                OutlinedButton(onClick = {
                    val authorization = family.current
                    if (!confirmOff) confirmOff = true else scope.launch {
                        try { family.turnOff(authorization) }
                        catch (cancelled: CancellationException) { throw cancelled }
                        catch (failure: Exception) { error = failure.message ?: "Could not turn profiles off." }
                    }
                }) { Text(if (confirmOff) "Confirm: turn off household profiles" else "Turn off household profiles") }
            }
        }
        error?.let { item { Text(it, color = ErrorText) } }
        item { OutlinedButton(onClick = onClose) { Text("Back") } }
    }
}

@Composable
private fun DisabledHousehold(onClose: () -> Unit) {
    val family = LocalContext.current.container.family
    var verifying by remember { mutableStateOf(false) }
    if (verifying) {
        PinPrompt("Turn on household profiles", onCancel = { verifying = false }) { pin, epoch -> family.unlock(HouseholdProfile.ADMIN, pin, epoch) }
        return
    }
    Column(Modifier.padding(ScreenPadding), verticalArrangement = Arrangement.spacedBy(20.dp)) {
        Text("Household profiles are off", style = MaterialTheme.typography.headlineLarge)
        Text("The full library is visible. Your saved profiles, permissions and viewing histories are kept. Enter your existing Admin PIN to turn protection back on.", color = SecondaryText)
        Button(onClick = { verifying = true }) { Text("Turn on with Admin PIN") }
        OutlinedButton(onClick = onClose) { Text("Back") }
    }
}

@Composable
private fun SetupHousehold(onClose: () -> Unit) {
    val family = LocalContext.current.container.family
    val setupEpoch by family.authenticationEpochs.collectAsState()
    var pin by remember(setupEpoch) { mutableStateOf("") }
    var confirmation by remember(setupEpoch) { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    LazyColumn(contentPadding = PaddingValues(ScreenPadding), verticalArrangement = Arrangement.spacedBy(20.dp)) {
        item { Text("A library for your household", style = MaterialTheme.typography.headlineLarge) }
        item { Text("Create an Admin PIN, then choose the folders and age ratings each viewer can access. Restricted media stays hidden. Your existing library and viewing history stay with Admin.", color = SecondaryText) }
        item { Text("Profiles lock when MediaVault leaves the screen. Keep this PIN somewhere safe; it cannot be recovered in the app.", color = SecondaryText) }
        item { PinField(pin, { pin = it }, "Create six-digit Admin PIN", !saving) }
        item { PinField(confirmation, { confirmation = it }, "Confirm Admin PIN", !saving) }
        item { Button(enabled = !saving && PinVerifier.valid(pin) && PinVerifier.valid(confirmation), onClick = {
            val first = pin; val second = confirmation; val requestEpoch = setupEpoch; saving = true
            scope.launch {
                try { family.setup(first, second, requestEpoch); pin = ""; confirmation = "" }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (failure: Exception) { error = failure.message ?: "Could not save household profiles." }
                finally { saving = false }
            }
        }) { Text(if (saving) "Creating…" else "Create household") } }
        error?.let { item { Text(it, color = ErrorText) } }
        item { OutlinedButton(enabled = !saving, onClick = onClose) { Text("Back") } }
    }
}

@Composable
private fun ProfileEditor(original: HouseholdProfile, onClose: () -> Unit) {
    val container = LocalContext.current.container
    val family = container.family
    var draft by remember(original.id) { mutableStateOf(original) }
    var pin by remember { mutableStateOf("") }
    var confirmation by remember { mutableStateOf("") }
    var removePin by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    var deleting by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val sources by remember { container.database.sources().observeAll() }.collectAsStateWithLifecycle(emptyList())
    BackHandler { if (!saving) onClose() }
    LazyColumn(contentPadding = PaddingValues(ScreenPadding), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        item { Text(if (original.isAdmin) "Admin PIN" else "Viewer permissions", style = MaterialTheme.typography.headlineLarge) }
        if (!original.isAdmin) {
            item { TvTextField(draft.name, { draft = draft.copy(name = it.take(30)) }, "Viewer name", Modifier.width(600.dp)) }
            item { Text("Allowed folders", style = MaterialTheme.typography.titleLarge) }
            item { Text("Only selected folders are visible, including their subfolders. New NAS connections stay hidden until you allow them.", color = SecondaryText) }
            if (draft.folders.isEmpty()) item { Text("No folders selected. This viewer's library will be empty.", color = SecondaryText) }
            draft.folders.forEach { grant -> item {
                OutlinedButton(onClick = { draft = draft.copy(folders = draft.folders - grant) }) {
                    Text("Remove ${sources.firstOrNull { it.id == grant.sourceId }?.name ?: "Removed NAS"} / ${grant.path.ifEmpty { "All folders" }}")
                }
            } }
            sources.forEach { source -> item(key = source.id) { PermissionFolderPicker(source) { folder ->
                val grant = FolderAccess(source.id, folder, caseSensitive = source.sourceType in setOf("webdav", JELLYFIN))
                if (grant !in draft.folders) draft = draft.copy(folders = draft.folders + grant)
            } } }
            item { RatingSelector("US movies", FamilyPolicy.movieRatings, draft.movieLimit) { draft = draft.copy(movieLimit = it) } }
            item { RatingSelector("US TV series rating", FamilyPolicy.tvRatings, draft.tvLimit) { draft = draft.copy(tvLimit = it) } }
            item { Text("When a rating limit is set, unrated or unrecognized videos stay hidden. TV limits use the series rating, not individual episode ratings. Photos and music follow folder permissions. TMDB supplies ratings; an incorrect title match can have an incorrect rating, so choose trusted folders too.", color = SecondaryText) }
        }
        item { PinField(pin, { pin = it; removePin = false }, if (original.pin != null) "New six-digit PIN (leave blank to keep)" else "Optional six-digit PIN", !saving) }
        if (pin.isNotEmpty()) item { PinField(confirmation, { confirmation = it }, "Confirm new PIN", !saving) }
        if (!original.isAdmin && original.pin != null) item { OutlinedButton(onClick = { removePin = !removePin; pin = "" }) { Text(if (removePin) "PIN will be removed · Keep PIN instead" else "Remove viewer PIN") } }
        item { Button(enabled = !saving && draft.name.isNotBlank(), onClick = {
            if (pin.isNotEmpty() && (pin != confirmation || !PinVerifier.valid(pin))) { message = "Enter the same six-digit PIN twice."; return@Button }
            val submitted = pin; val authorization = family.current; pin = ""; confirmation = ""; saving = true
            scope.launch {
                try { family.saveProfile(draft, submitted, removePin, authorization); onClose() }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (failure: Exception) { message = failure.message ?: "Could not save this profile." }
                finally { saving = false }
            }
        }) { Text(if (saving) "Saving…" else "Save profile") } }
        if (!original.isAdmin && family.profiles.any { it.id == original.id }) item {
            OutlinedButton(enabled = !saving, onClick = {
                val authorization = family.current
                if (!deleting) deleting = true else scope.launch {
                    try { family.deleteProfile(original.id, authorization); container.database.profileHistory().deleteProfile(original.id); onClose() }
                    catch (failure: Exception) { message = failure.message }
                }
            }) { Text(if (deleting) "Confirm delete profile and its history" else "Delete profile") }
        }
        message?.let { item { Text(it, color = ErrorText) } }
        item { OutlinedButton(enabled = !saving, onClick = onClose) { Text("Back") } }
    }
}

@Composable
private fun RatingSelector(label: String, values: List<String>, selected: String?, onSelect: (String?) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        OutlinedButton(onClick = { expanded = !expanded }) { Text("$label: ${selected?.let { "Up to $it" } ?: "No rating limit"} ▾") }
        selected?.let { Text("Allowed: ${values.take(values.indexOf(it) + 1).joinToString(", ")}. Unrated videos are hidden.", color = SecondaryText) }
        if (expanded) {
            (listOf<String?>(null) + values).forEach { rating ->
                OutlinedButton(onClick = { onSelect(rating); expanded = false }) { Text(rating?.let { "Up to $it" } ?: "No rating limit · Includes unrated") }
            }
        }
    }
}

@Composable
private fun PermissionFolderPicker(source: SourceEntity, onSelect: (String) -> Unit) {
    if (source.sourceType == JELLYFIN) {
        OutlinedButton(onClick = { onSelect("") }) { Text("Allow Jellyfin library · ${source.name}") }
        return
    }
    val container = LocalContext.current.container
    var expanded by remember { mutableStateOf(false) }
    var path by remember(source.id) { mutableStateOf(source.rootPath.replace('\\', '/').trim('/')) }
    var folders by remember { mutableStateOf(emptyList<String>()) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var ready by remember { mutableStateOf(false) }
    LaunchedEffect(expanded, path) {
        if (!expanded) return@LaunchedEffect
        loading = true; ready = false; error = null; folders = emptyList()
        try {
            container.family.requireAdmin()
            val config = withContext(Dispatchers.IO) { source.config(container.secrets).copy(rootPath = path) }
            folders = NasBrowser().listFolders(config)
            container.family.requireAdmin(); ready = true
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) { error = SmbService.describe(failure) }
        finally { loading = false }
    }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        OutlinedButton(onClick = { expanded = !expanded }) { Text("Choose folders · ${source.name} ▾") }
        if (expanded) {
            Text("${source.name} / ${path.ifBlank { "Share root" }}", color = SecondaryText)
            if (path != source.rootPath.replace('\\', '/').trim('/')) OutlinedButton(onClick = { path = path.substringBeforeLast('/', "") }) { Text("Up one folder") }
            Button(enabled = ready && !loading, onClick = { onSelect(path); expanded = false }) { Text("Allow this folder and its subfolders") }
            if (loading) Text("Loading folders…", color = SecondaryText)
            folders.forEach { folder -> OutlinedButton(enabled = !loading, onClick = { path = listOf(path, folder).filter(String::isNotEmpty).joinToString("/") }) { Text("$folder ▸") } }
            if (ready && folders.isEmpty()) Text("No subfolders.", color = SecondaryText)
            error?.let { Text(it, color = ErrorText) }
        }
    }
}
