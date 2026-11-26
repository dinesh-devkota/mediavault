package com.dineshdevkota.cinevault.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Text
import com.dineshdevkota.cinevault.container
import com.dineshdevkota.cinevault.data.MovieEntity
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

internal class WatchSelection {
    var selecting by mutableStateOf(false)
    var ids by mutableStateOf(emptySet<String>())
    var dialogIds by mutableStateOf<Set<String>?>(null)
    var wholeScopeDialog by mutableStateOf(false)
    var message by mutableStateOf<String?>(null)

    fun toggle(items: Collection<String>) {
        ids = if (ids.containsAll(items)) ids - items.toSet() else ids + items
    }

    fun finish() {
        selecting = false
        ids = emptySet()
    }
}

/** The caller supplies the current filtered scope, including current source exclusions. */
@Composable
internal fun BulkWatchControls(
    items: List<MovieEntity>, scopeTitle: String, selection: WatchSelection,
    modifier: Modifier = Modifier, allowWholeScope: Boolean = false,
    wholeScopeItems: List<MovieEntity> = items, wholeScopeTitle: String = scopeTitle,
    navigationFocus: FocusRequester? = null,
) {
    val container = LocalContext.current.container
    val scope = rememberCoroutineScope()
    val available = remember(items) { items.map { it.id }.toSet() }
    val selected = selection.ids.intersect(available)
    val ownFocus = remember { FocusRequester() }
    val actionFocus = navigationFocus ?: ownFocus
    var restoreFocus by remember { mutableStateOf(false) }
    var toolbarPlaced by remember { mutableStateOf(false) }
    val windowFocused = LocalWindowInfo.current.isWindowFocused
    var saving by remember { mutableStateOf(false) }
    var chooseCollection by remember { mutableStateOf(false) }
    if (chooseCollection) CollectionPicker(selected) { chooseCollection = false }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(available) {
        if (selection.ids.isNotEmpty() && selected.isEmpty()) restoreFocus = true
        selection.ids = selected
    }
    LaunchedEffect(restoreFocus, toolbarPlaced, windowFocused) {
        if (restoreFocus && toolbarPlaced && windowFocused && actionFocus.requestFocus()) restoreFocus = false
    }
    fun closeDialog() {
        actionFocus.requestFocus()
        selection.dialogIds = null
        error = null
        restoreFocus = true
    }
    BackHandler(enabled = selection.selecting && selection.dialogIds == null) {
        selection.finish()
        restoreFocus = true
    }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        AdaptiveActions(12.dp) {
            // A stable button remains attached when watched filters remove every selected card.
            OutlinedButton(
                modifier = Modifier.focusRequester(actionFocus).onGloballyPositioned { toolbarPlaced = true }
                    .testTag("bulk-select"),
                onClick = {
                    selection.message = null
                    if (selection.selecting) selection.finish()
                    else if (available.isNotEmpty()) selection.selecting = true
                    else selection.message = "No matching video files to select."
                },
            ) { Text(if (selection.selecting) "Done selecting" else "Select") }
            if (selection.selecting) {
                OutlinedButton(enabled = selected.isNotEmpty(), onClick = { chooseCollection = true }) { Text("Collections") }
                OutlinedButton(enabled = available.isNotEmpty(),
                    onClick = { selection.ids = available }) { Text("Select all results") }
                OutlinedButton(onClick = { selection.ids = emptySet() }) { Text("Clear") }
                Button(enabled = selected.isNotEmpty(), onClick = {
                    selection.wholeScopeDialog = false
                    selection.dialogIds = selected
                }) {
                    Text("Watched status (${selected.size})")
                }
            } else if (allowWholeScope) {
                OutlinedButton(enabled = wholeScopeItems.isNotEmpty(), onClick = {
                    selection.wholeScopeDialog = true
                    selection.dialogIds = wholeScopeItems.map { it.id }.toSet()
                }) {
                    Text("Watched status")
                }
            }
        }
        if (selection.selecting) Text("${selected.size} selected · Select cards to add or remove files.",
            style = MaterialTheme.typography.bodySmall, color = SecondaryText)
        selection.message?.let { Text(it, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
            style = MaterialTheme.typography.bodySmall, color = SecondaryText) }
    }
    val requested = selection.dialogIds ?: return
    val targets = requested.intersect(if (selection.wholeScopeDialog) wholeScopeItems.map { it.id }.toSet() else available)
    Dialog(onDismissRequest = { if (!saving) closeDialog() }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        val cancelFocus = remember { FocusRequester() }
        var placed by remember { mutableStateOf(false) }
        var focused by remember { mutableStateOf(false) }
        val dialogFocused = LocalWindowInfo.current.isWindowFocused
        LaunchedEffect(placed, dialogFocused) {
            if (placed && dialogFocused && !focused) focused = cancelFocus.requestFocus()
        }
        Column(Modifier.width(570.dp).background(SurfaceColor, RoundedCornerShape(16.dp)).padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text("Change watched status", style = MaterialTheme.typography.headlineSmall)
            Text(if (selection.wholeScopeDialog) wholeScopeTitle else scopeTitle, style = MaterialTheme.typography.titleMedium)
            Text("${targets.size} selected ${if (targets.size == 1) "file" else "files"}. Saved resume positions will be cleared.",
                style = MaterialTheme.typography.bodyMedium)
            if (targets.isEmpty()) Text("These files are no longer in the current results.", color = SecondaryText)
            error?.let { Text(it, color = ErrorText) }
            AdaptiveActions(12.dp) {
                for (watched in listOf(true, false)) {
                    Button(enabled = !saving && targets.isNotEmpty(), onClick = {
                        // Preserve the parent window's focus before a watched filter removes
                        // cards or a quick action's show disappears behind the dialog.
                        actionFocus.requestFocus()
                        saving = true
                        error = null
                        scope.launch {
                            try {
                                val count = container.editor.setWatched(targets, watched)
                                selection.message = "$count ${if (count == 1) "file" else "files"} marked ${if (watched) "watched" else "unwatched"}."
                                selection.finish()
                                closeDialog()
                            } catch (cancelled: CancellationException) {
                                throw cancelled
                            } catch (_: Exception) {
                                error = "Could not update watched status. Try again."
                            } finally {
                                saving = false
                            }
                        }
                    }) { Text(if (watched) "Mark watched" else "Mark unwatched") }
                }
                OutlinedButton(enabled = !saving, modifier = Modifier.focusRequester(cancelFocus)
                    .onGloballyPositioned { placed = true }, onClick = { closeDialog() }) { Text("Cancel") }
            }
            if (saving) Text("Saving…", color = SecondaryText)
        }
    }
}

@Composable
internal fun SelectionBadge(selected: Boolean, modifier: Modifier = Modifier) {
    Text(if (selected) "✓ Selected" else "○ Select", modifier = modifier
        .background(SurfaceColor, RoundedCornerShape(6.dp)).padding(horizontal = 10.dp, vertical = 6.dp),
        style = MaterialTheme.typography.labelMedium, color = if (selected) Accent else SecondaryText)
}
