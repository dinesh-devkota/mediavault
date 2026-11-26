package com.dineshdevkota.cinevault.cloud

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.room.withTransaction
import com.dineshdevkota.cinevault.data.CineVaultDatabase
import com.dineshdevkota.cinevault.data.SecretBox
import com.dineshdevkota.cinevault.data.SourceEntity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** The OS owns Drive credentials. MediaVault only stores selected read grants in its protected source record. */
internal class GoogleDriveSourceStore(
    context: Context,
    private val database: CineVaultDatabase,
    private val secrets: SecretBox,
    private val documents: GoogleDriveDocuments,
) {
    private val resolver = context.contentResolver
    private val mutex = Mutex()

    suspend fun save(
        id: String, requestedName: String, original: SourceEntity?, selected: DriveDocumentGrant?,
        authorize: () -> Unit,
    ): SourceEntity = withContext(Dispatchers.IO) {
        mutex.withLock {
            authorize()
            if (original != null) check(original.sourceType == GOOGLE_DRIVE_DOCUMENTS)
            val prior = original?.let { DriveDocumentGrant.decode(secrets.decrypt(it.encryptedPassword)) }
            if (prior != null && selected != null && prior != selected) {
                throw GoogleDriveDocumentsException("Reconnect the same Google Drive selection, or add another source.")
            }
            val grant = selected ?: requireNotNull(prior)
            val newlyGranted = mutableListOf<Uri>()
            try {
                val label = if (selected != null) {
                    for (text in selected.uris) {
                        authorize()
                        val uri = Uri.parse(text)
                        enforceDriveUri(uri, selected.tree != null)
                        if (resolver.persistedUriPermissions.none { it.uri == uri && it.isReadPermission }) {
                            resolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            newlyGranted += uri
                        }
                    }
                    documents.verify(grant)
                } else original?.name ?: "Google Drive"
                val source = (original ?: SourceEntity(
                    id = id, name = label, host = "google-drive", share = "selected", username = "android-documents",
                    encryptedPassword = secrets.encrypt(grant.encode()), sourceType = GOOGLE_DRIVE_DOCUMENTS,
                )).copy(name = requestedName.trim().ifBlank { label })
                database.withTransaction {
                    authorize()
                    val current = database.sources().get(id)
                    check(current?.copy(lastScanAt = original?.lastScanAt) == original) { "The source changed. Open it again." }
                    database.sources().upsert(source.copy(lastScanAt = current?.lastScanAt))
                }
                source
            } catch (failure: Exception) {
                withContext(NonCancellable) { releaseUnused(newlyGranted) }
                throw failure
            }
        }
    }

    suspend fun remove(source: SourceEntity, authorize: () -> Unit) = withContext(Dispatchers.IO) {
        mutex.withLock {
            val grantUris = runCatching { DriveDocumentGrant.decode(secrets.decrypt(source.encryptedPassword)) }
                .getOrNull()?.uris.orEmpty().map(Uri::parse)
            withContext(NonCancellable) {
                database.withTransaction {
                    authorize()
                    val current = database.sources().get(source.id)
                    check(current?.copy(lastScanAt = source.lastScanAt) == source) { "The source changed. Open it again." }
                    database.sources().delete(source.id)
                }
                releaseUnused(grantUris)
            }
        }
    }

    private suspend fun releaseUnused(uris: List<Uri>) {
        if (uris.isEmpty()) return
        val referenced = try {
            database.sources().all().filter { it.sourceType == GOOGLE_DRIVE_DOCUMENTS }
                .flatMap { DriveDocumentGrant.decode(secrets.decrypt(it.encryptedPassword)).uris }.toSet()
        } catch (_: Exception) {
            return // An unreadable source must not lose a grant another source might be using.
        }
        uris.filter { it.toString() !in referenced }.forEach { uri ->
            runCatching { resolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
        }
    }
}

internal fun enforceDriveUri(uri: Uri, tree: Boolean) {
    val expected = if (tree) "tree" else "document"
    if (uri.scheme != ContentResolver.SCHEME_CONTENT || uri.authority != GOOGLE_DRIVE_AUTHORITY ||
        uri.query != null || uri.fragment != null || uri.pathSegments.size != 2 ||
        uri.pathSegments.firstOrNull() != expected || uri.pathSegments.last().isBlank()) {
        throw GoogleDriveDocumentsException("Select from Google Drive in Android's file picker.")
    }
}
