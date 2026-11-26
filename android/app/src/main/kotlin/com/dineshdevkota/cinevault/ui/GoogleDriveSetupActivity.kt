@file:OptIn(ExperimentalTvMaterial3Api::class)

package com.dineshdevkota.cinevault.ui

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.Text
import com.dineshdevkota.cinevault.cloud.DriveDocumentGrant
import com.dineshdevkota.cinevault.cloud.GOOGLE_DRIVE_DOCUMENTS
import com.dineshdevkota.cinevault.cloud.GoogleDriveDocuments
import com.dineshdevkota.cinevault.cloud.GoogleDriveDocumentsException
import com.dineshdevkota.cinevault.cloud.enforceDriveUri
import com.dineshdevkota.cinevault.container
import com.dineshdevkota.cinevault.data.SourceEntity
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import java.util.UUID

internal class GoogleDriveSetupActivity : ComponentActivity() {
    // The Android picker may lock the household session while this Activity is in the background.
    // Keep its response private until the admin unlocks the editor again.
    private var selection by mutableStateOf<DriveDocumentGrant?>(null)
    private var selectionError by mutableStateOf<String?>(null)
    private var folderRequest = false
    private val picker = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { response ->
        val data = response.data
        if (response.resultCode != Activity.RESULT_OK || data == null) return@registerForActivityResult
        try {
            val uris = (data.clipData?.let { clip -> (0 until clip.itemCount).map { clip.getItemAt(it).uri } }
                ?: listOfNotNull(data.data)).distinct().sortedBy { it.toString() }
            check(data.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0) { "Google Drive did not grant read access." }
            uris.forEach { enforceDriveUri(it, folderRequest) }
            if (folderRequest && uris.size != 1) throw GoogleDriveDocumentsException("Select one Google Drive folder.")
            if (!folderRequest && uris.size !in 1..DriveDocumentGrant.MAX_DOCUMENTS) {
                throw GoogleDriveDocumentsException("Select 1 to ${DriveDocumentGrant.MAX_DOCUMENTS} Google Drive files, or choose a folder.")
            }
            selection = if (folderRequest) DriveDocumentGrant(tree = uris.single().toString())
                else DriveDocumentGrant(documents = uris.map { it.toString() })
            selectionError = null
        } catch (failure: Exception) {
            selection = null
            selectionError = failure.message
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        folderRequest = savedInstanceState?.getBoolean("drive_folder_request") == true
        setCineVaultContent { DriveSetup(intent.getStringExtra("source_id")) }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean("drive_folder_request", folderRequest)
    }

    @Composable
    private fun DriveSetup(sourceId: String?) {
        val scope = rememberCoroutineScope()
        var existing by remember { mutableStateOf<SourceEntity?>(null) }
        var ready by remember { mutableStateOf(sourceId == null) }
        val draft = remember { sourceId ?: UUID.randomUUID().toString() }
        var name by remember { mutableStateOf("") }
        var busy by remember { mutableStateOf(false) }
        var removal by remember { mutableStateOf(false) }
        var error by remember { mutableStateOf<String?>(null) }
        val canFolder = remember { GoogleDriveDocuments.canPick(this, Intent.ACTION_OPEN_DOCUMENT_TREE) }
        val canFiles = remember { GoogleDriveDocuments.canPick(this, Intent.ACTION_OPEN_DOCUMENT) }

        LaunchedEffect(sourceId) {
            if (sourceId == null) return@LaunchedEffect
            val source = container.database.sources().get(sourceId)?.takeIf { it.sourceType == GOOGLE_DRIVE_DOCUMENTS }
            if (source == null) finish()
            else { existing = source; name = source.name; ready = true }
        }
        if (!ready) return

        fun browse(folder: Boolean) {
            try {
                container.family.requireAdmin()
                folderRequest = folder
                error = null
                picker.launch(GoogleDriveDocuments.picker(if (folder) Intent.ACTION_OPEN_DOCUMENT_TREE else Intent.ACTION_OPEN_DOCUMENT))
            } catch (_: ActivityNotFoundException) { error = "Android's file picker is unavailable on this device." }
        }

        fun submit(work: suspend (() -> Unit) -> Unit) {
            if (busy) return
            val session = container.family.current
            fun authorize() {
                container.family.requireAdmin()
                check(container.family.isCurrent(session)) { "Unlock Admin again to finish this change." }
            }
            busy = true
            error = null
            scope.launch {
                try { authorize(); work(::authorize) }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (failure: Exception) {
                    error = when (failure) {
                        is GoogleDriveDocumentsException, is IllegalStateException -> failure.message
                        else -> "Unable to open this Google Drive selection. Choose it again in Android's file picker."
                    }
                } finally { busy = false }
            }
        }

        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(ScreenPadding),
            verticalArrangement = Arrangement.spacedBy(16.dp)) {
            ScreenHeader(if (sourceId == null) "Add Google Drive" else "Edit Google Drive source", kicker = "SOURCES", showBack = false)
            Text("Choose Google Drive in Android's file picker. Select a folder, or choose media and any matching subtitle files together.")
            if (existing != null) Text("To reconnect, choose the same selection. Add another source for a different selection.")
            TvTextField(name, { name = it }, "Source name (optional)", Modifier.fillMaxWidth(), enabled = !busy)
            AdaptiveActions {
                if (canFolder) OutlinedButton(enabled = !busy, onClick = { browse(folder = true) }) { Text("Choose folder") }
                if (canFiles) OutlinedButton(enabled = !busy, onClick = { browse(folder = false) }) { Text("Choose files") }
            }
            val picked = selection
            if (picked != null) Text(if (picked.tree != null) "Google Drive folder selected" else "${picked.documents.size} Google Drive files selected")
            if (!canFolder && !canFiles) Text("Google Drive and Android's file picker are required to reconnect this source.")
            (error ?: selectionError)?.let { NasStatusPanel("Google Drive needs attention", it, error = true) }
            if (busy) NasStatusPanel("Saving Google Drive source", working = true)
            AdaptiveActions {
                val current = existing
                Button(enabled = !busy && (picked != null || current != null && name.trim() != current.name), onClick = {
                    submit { authorize ->
                        container.googleDriveSources.save(draft, name, current, picked, authorize)
                        if (picked != null) container.scope.launch { container.scanner.scan(draft) }
                        finish()
                    }
                }) { Text(if (picked != null) "Save and scan" else "Save source name") }
                if (current != null) OutlinedButton(enabled = !busy, onClick = {
                    if (!removal) removal = true
                    else submit { authorize -> container.googleDriveSources.remove(current, authorize); finish() }
                }) { Text(if (removal) "Confirm remove Google Drive source" else "Remove source") }
                OutlinedButton(enabled = !busy, onClick = ::finish) { Text("Cancel") }
            }
        }
    }

    companion object {
        fun start(context: Context, sourceId: String? = null) {
            context.startActivity(Intent(context, GoogleDriveSetupActivity::class.java).putExtra("source_id", sourceId))
        }
    }
}
