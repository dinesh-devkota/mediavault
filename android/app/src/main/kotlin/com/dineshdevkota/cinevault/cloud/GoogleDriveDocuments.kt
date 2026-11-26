package com.dineshdevkota.cinevault.cloud

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import com.dineshdevkota.cinevault.core.MediaFile
import com.dineshdevkota.cinevault.core.RemoteFile
import com.dineshdevkota.cinevault.core.SubtitleSidecars
import com.dineshdevkota.cinevault.smb.FileSourceTransport
import com.dineshdevkota.cinevault.smb.NasEntry
import com.dineshdevkota.cinevault.smb.RemoteHandle
import com.dineshdevkota.cinevault.smb.ScanProgress
import com.dineshdevkota.cinevault.smb.SourceConfig
import com.dineshdevkota.cinevault.smb.SubtitleDiscovery
import com.dineshdevkota.cinevault.smb.SubtitleFile
import com.dineshdevkota.cinevault.webdav.DavAddress
import java.io.IOException
import java.io.InputStream
import java.util.Base64
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.runInterruptible
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

internal const val GOOGLE_DRIVE_DOCUMENTS = "google-drive-documents"
internal const val GOOGLE_DRIVE_PACKAGE = "com.google.android.apps.docs"
internal const val GOOGLE_DRIVE_AUTHORITY = "com.google.android.apps.docs.storage"

internal class GoogleDriveDocumentsException(message: String) : IOException(message)

@Serializable
internal data class DriveDocumentGrant(val tree: String? = null, val documents: List<String> = emptyList()) {
    init {
        require((tree != null) != documents.isNotEmpty())
        require(documents.size <= MAX_DOCUMENTS && documents.distinct().size == documents.size)
    }

    fun encode(): String = Json.encodeToString(serializer(), this)
    val uris: List<String> get() = if (tree == null) documents else listOf(tree)

    companion object {
        // Keep multi-file selections below Android's per-app persisted URI budget.
        const val MAX_DOCUMENTS = 64
        fun decode(text: String): DriveDocumentGrant = try { Json.decodeFromString(serializer(), text) }
        catch (_: IllegalArgumentException) { throw GoogleDriveDocumentsException("Reconnect this Google Drive selection in Sources.") }
    }
}

internal object DriveDocumentPath {
    const val ROOT = "gdrive"

    fun child(parent: String, id: String, name: String): String {
        require(id.isNotBlank() && id.length <= 2048 && DavAddress.safeComponent(name))
        val token = Base64.getUrlEncoder().withoutPadding().encodeToString(id.encodeToByteArray())
        return "$parent/$token~$name"
    }

    fun parts(path: String): List<Pair<String, String>>? {
        if (!path.startsWith("$ROOT/")) return null
        return path.removePrefix("$ROOT/").split('/').map { component ->
            val token = component.substringBefore('~')
            val name = component.substringAfter('~', "")
            if (token.isEmpty() || token.length > 8192 || !DavAddress.safeComponent(name)) return null
            val id = try { Base64.getUrlDecoder().decode(token).decodeToString(throwOnInvalidSequence = true) }
            catch (_: IllegalArgumentException) { return null }
            catch (_: java.nio.charset.CharacterCodingException) { return null }
            if (id.isBlank() || id.length > 2048) return null
            id to name
        }
    }

    fun fileID(path: String): String? = parts(path)?.lastOrNull()?.first
    fun parentID(path: String): String? = parts(path)?.dropLast(1)?.lastOrNull()?.first
    fun displayPath(path: String): String? = parts(path)?.joinToString("/") { it.second }
}

internal data class DriveDocument(val id: String, val name: String, val mime: String, val size: Long) {
    val folder: Boolean get() = mime == Document.MIME_TYPE_DIR
}

internal interface DriveDocumentHandle : RemoteHandle {
    fun stream(position: Long, authorize: () -> Unit): InputStream
    override fun stream(position: Long): InputStream = stream(position) {}
}

internal interface DriveDocumentAccess {
    fun hasGrant(uri: Uri): Boolean
    fun document(uri: Uri): DriveDocument
    fun children(uri: Uri): List<DriveDocument>
    fun open(uri: Uri, size: Long): RemoteHandle
}

/** Read-only access backed by Android's Google Drive DocumentsProvider and user-selected grants. */
class GoogleDriveDocuments internal constructor(
    private val access: DriveDocumentAccess,
    private val authority: String,
) : FileSourceTransport {
    constructor(context: Context) : this(AndroidDriveDocumentAccess(context.contentResolver), GOOGLE_DRIVE_AUTHORITY)

    override suspend fun listEntries(config: SourceConfig): List<NasEntry> = runInterruptible(Dispatchers.IO) {
        val grant = DriveDocumentGrant.decode(config.password)
        val atRoot = config.rootPath.isEmpty() || config.rootPath == DriveDocumentPath.ROOT
        val entries = if (grant.tree == null) {
            if (!atRoot) throw GoogleDriveDocumentsException("Choose a Google Drive folder to browse its contents.")
            checkedEntries(grant).map { it.second }.filterNot { it.folder }
        } else {
            val chain = if (atRoot) emptyList() else DriveDocumentPath.parts(config.rootPath)
                ?: throw GoogleDriveDocumentsException("This Google Drive folder is invalid.")
            val (tree, root) = checkedEntries(grant).single()
            var parent = root.id
            for ((id, name) in chain) {
                val children = access.children(DocumentsContract.buildChildDocumentsUriUsingTree(tree, parent))
                if (children.none { it.folder && it.id == id && it.name == name && !MediaFile.shouldSkipDirectory(name) }) {
                    throw GoogleDriveDocumentsException("This folder is outside the selected Google Drive folder.")
                }
                parent = id
            }
            access.children(DocumentsContract.buildChildDocumentsUriUsingTree(tree, parent))
        }
        entries.filter { DavAddress.safeComponent(it.name) && (!it.folder || !MediaFile.shouldSkipDirectory(it.name)) }
            .map { NasEntry(it.name, it.folder) }
            .distinct()
            .sortedWith(compareByDescending<NasEntry> { it.isDirectory }.thenBy { it.name })
    }

    override suspend fun testConnection(config: SourceConfig) {
        runInterruptible(Dispatchers.IO) { verify(DriveDocumentGrant.decode(config.password)) }
    }

    override suspend fun reset(sourceId: String) = Unit

    internal fun verify(grant: DriveDocumentGrant): String {
        val entries = checkedEntries(grant)
        if (grant.tree != null) {
            if (!entries.single().second.folder) throw GoogleDriveDocumentsException("Choose a folder in Google Drive.")
            // Validate directory access before displaying the selection as connected.
            val root = entries.single()
            access.children(DocumentsContract.buildChildDocumentsUriUsingTree(root.first, root.second.id))
            return root.second.name
        }
        if (entries.any { it.second.folder } || entries.none { MediaFile.shouldIndex(it.second.name, it.second.size) }) {
            throw GoogleDriveDocumentsException("Choose at least one playable video, audio file or photo in Google Drive.")
        }
        return "Google Drive selection"
    }

    override suspend fun scan(config: SourceConfig, onProgress: suspend (ScanProgress) -> Unit): List<RemoteFile> {
        val grant = DriveDocumentGrant.decode(config.password)
        val roots = runInterruptible(Dispatchers.IO) { checkedEntries(grant) }
        val pending = ArrayDeque<Pair<String, String>>()
        if (grant.tree != null) pending.add(DriveDocumentPath.ROOT to roots.single().second.id)
        val result = mutableListOf<RemoteFile>()
        val visited = mutableSetOf<String>()
        var folderCount = 0

        suspend fun collect(parent: String, items: List<DriveDocument>) {
            val batch = mutableListOf<RemoteFile>()
            for (item in items) {
                currentCoroutineContext().ensureActive()
                if (!visited.add(item.id) || !DavAddress.safeComponent(item.name)) continue
                if (visited.size > MAX_ENTRIES) throw GoogleDriveDocumentsException("Choose a smaller Google Drive folder.")
                val path = DriveDocumentPath.child(parent, item.id, item.name)
                if (item.folder) {
                    if (grant.tree != null && !MediaFile.shouldSkipDirectory(item.name)) pending.add(path to item.id)
                } else if (MediaFile.shouldIndex(item.name, item.size) && accepts(config, path)) {
                    val file = RemoteFile(path, item.size)
                    batch += file
                    result += file
                    if (batch.size == 100) {
                        onProgress(ScanProgress(batch.toList(), result.size, folderCount))
                        batch.clear()
                    }
                }
            }
            onProgress(ScanProgress(batch.toList(), result.size, folderCount))
        }

        if (grant.tree == null) collect(DriveDocumentPath.ROOT, roots.map { it.second })
        while (pending.isNotEmpty()) {
            val (path, folder) = pending.removeLast()
            val children = runInterruptible(Dispatchers.IO) {
                val tree = treeUri(checkNotNull(grant.tree))
                access.children(DocumentsContract.buildChildDocumentsUriUsingTree(tree, folder))
            }
            folderCount++
            collect(path, children)
        }
        return result
    }

    override suspend fun hasPlayableContent(config: SourceConfig, path: String): Boolean =
        accepts(config, path, playback = true)

    private suspend fun accepts(config: SourceConfig, path: String, playback: Boolean = false): Boolean {
        if (!MediaFile.requiresContentCheck(path)) return true
        val bytes = runInterruptible(Dispatchers.IO) { read(config, path, 1024, prefix = true) }
        return if (playback) MediaFile.isPlayableTransportStream(bytes) else MediaFile.isTransportStream(bytes)
    }

    override fun open(config: SourceConfig, path: String): RemoteHandle {
        val grant = DriveDocumentGrant.decode(config.password)
        val id = DriveDocumentPath.fileID(path) ?: throw GoogleDriveDocumentsException("This Google Drive file is invalid. Rescan the source.")
        val uri = if (grant.tree != null) DocumentsContract.buildDocumentUriUsingTree(treeUri(grant.tree), id)
            else grant.documents.asSequence().map(::documentUri).firstOrNull { DocumentsContract.getDocumentId(it) == id }
                ?: throw GoogleDriveDocumentsException("This file was not selected in Google Drive.")
        val item = access.document(uri)
        if (item.id != id || item.folder || item.size <= 0) throw GoogleDriveDocumentsException("Google Drive could not open this file.")
        return access.open(uri, item.size)
    }

    override suspend fun subtitles(
        config: SourceConfig, path: String, preferredLanguage: String?, authorize: () -> Unit,
    ): SubtitleDiscovery {
        authorize()
        val display = DriveDocumentPath.displayPath(path) ?: return SubtitleDiscovery(emptyList())
        val grant = DriveDocumentGrant.decode(config.password)
        val entries = runInterruptible(Dispatchers.IO) {
            if (grant.tree == null) checkedEntries(grant).map { it.second }
            else {
                val tree = treeUri(grant.tree)
                val parent = DriveDocumentPath.parentID(path) ?: DocumentsContract.getTreeDocumentId(tree)
                access.children(DocumentsContract.buildChildDocumentsUriUsingTree(tree, parent))
            }
        }
        authorize()
        val candidates = entries.take(SubtitleSidecars.MAX_DIRECTORY_ENTRIES).filter {
            !it.folder && it.size in 1L..SubtitleSidecars.MAX_BYTES.toLong() && DavAddress.safeComponent(it.name)
        }.mapNotNull { file ->
            val sibling = display.substringBeforeLast('/', "").let { if (it.isEmpty()) file.name else "$it/${file.name}" }
            val match = SubtitleSidecars.match(display, sibling, caseSensitive = true) ?: return@mapNotNull null
            val siblingPath = DriveDocumentPath.child(path.substringBeforeLast('/'), file.id, file.name)
            match to siblingPath
        }.sortedWith(compareByDescending<Pair<SubtitleSidecars.Match, String>> { it.first.language.equals(preferredLanguage, true) }
            .thenBy { it.second })
        val files = candidates.take(SubtitleSidecars.MAX_FILES).mapNotNull { (match, path) ->
            try {
                SubtitleFile(match.copy(path = path), runInterruptible(Dispatchers.IO) { read(config, path, SubtitleSidecars.MAX_BYTES, authorize = authorize) })
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: IOException) { null }
            catch (_: SecurityException) { null }
        }
        return SubtitleDiscovery(files, candidates.size > SubtitleSidecars.MAX_FILES || entries.size > SubtitleSidecars.MAX_DIRECTORY_ENTRIES)
    }

    private fun read(
        config: SourceConfig, path: String, maximum: Int, prefix: Boolean = false, authorize: () -> Unit = {},
    ): ByteArray {
        authorize()
        return open(config, path).use { handle ->
            authorize()
            if (!prefix && handle.length > maximum) throw GoogleDriveDocumentsException("The Google Drive file exceeds the size limit.")
            val result = ByteArray(minOf(handle.length, maximum.toLong()).toInt())
            handle.stream(0).use { stream ->
                var offset = 0
                while (offset < result.size) {
                    authorize()
                    val n = stream.read(result, offset, result.size - offset)
                    authorize()
                    if (n <= 0) throw GoogleDriveDocumentsException("The Google Drive file ended early.")
                    offset += n
                }
            }
            result
        }
    }

    private fun checkedEntries(grant: DriveDocumentGrant): List<Pair<Uri, DriveDocument>> =
        if (grant.tree != null) {
            val uri = treeUri(grant.tree)
            val root = DocumentsContract.getTreeDocumentId(uri)
            val item = access.document(DocumentsContract.buildDocumentUriUsingTree(uri, root))
            if (item.id != root || !item.folder) throw GoogleDriveDocumentsException("The selected Google Drive folder changed.")
            listOf(uri to item)
        } else grant.documents.map { text ->
            val uri = documentUri(text)
            val item = access.document(uri)
            if (item.id != DocumentsContract.getDocumentId(uri)) throw GoogleDriveDocumentsException("The selected Google Drive file changed.")
            uri to item
        }

    private fun treeUri(text: String): Uri = trustedUri(text).also {
        if (it.pathSegments.size != 2 || it.pathSegments.firstOrNull() != "tree") throw GoogleDriveDocumentsException("Select a Google Drive folder.")
    }

    private fun documentUri(text: String): Uri = trustedUri(text).also {
        if (it.pathSegments.size != 2 || it.pathSegments.firstOrNull() != "document") throw GoogleDriveDocumentsException("Select a file in Google Drive.")
    }

    private fun trustedUri(text: String): Uri {
        val uri = Uri.parse(text)
        if (uri.scheme != ContentResolver.SCHEME_CONTENT || uri.authority != authority || uri.query != null || uri.fragment != null) {
            throw GoogleDriveDocumentsException("Select from Google Drive in Android's file picker.")
        }
        if (!access.hasGrant(uri)) throw GoogleDriveDocumentsException("Google Drive access expired. Reconnect this source.")
        return uri
    }

    companion object {
        internal const val MAX_ENTRIES = 250_000
        internal fun canPick(context: Context, action: String): Boolean {
            val manager = context.packageManager
            return manager.resolveContentProvider(GOOGLE_DRIVE_AUTHORITY, 0)?.packageName == GOOGLE_DRIVE_PACKAGE &&
                picker(action).resolveActivity(manager) != null
        }
        internal fun picker(action: String): Intent = Intent(action).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            if (action == Intent.ACTION_OPEN_DOCUMENT) {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            }
        }
    }
}

private class AndroidDriveDocumentAccess(private val resolver: ContentResolver) : DriveDocumentAccess {
    override fun hasGrant(uri: Uri): Boolean = resolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission }
    override fun document(uri: Uri) = query(uri).singleOrNull()
        ?: throw GoogleDriveDocumentsException("The Google Drive folder or file is unavailable.")
    override fun children(uri: Uri): List<DriveDocument> = query(uri)
    private fun query(uri: Uri): List<DriveDocument> = try {
        resolver.query(uri, arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE,
            Document.COLUMN_SIZE), null, null, null)?.use { cursor ->
            if (cursor.extras.getBoolean(DocumentsContract.EXTRA_LOADING)) {
                throw GoogleDriveDocumentsException("Google Drive is still loading this folder. Scan again when it is ready.")
            }
            buildList {
                while (cursor.moveToNext()) {
                    if (size >= GoogleDriveDocuments.MAX_ENTRIES) throw GoogleDriveDocumentsException("Choose a smaller Google Drive folder.")
                    val id = cursor.getString(0) ?: continue
                    val name = cursor.getString(1) ?: continue
                    val mime = cursor.getString(2) ?: continue
                    add(DriveDocument(id, name, mime, if (cursor.isNull(3)) 0 else cursor.getLong(3)))
                }
            }
        } ?: throw GoogleDriveDocumentsException("Google Drive could not list this selection.")
    } catch (_: SecurityException) {
        throw GoogleDriveDocumentsException("Google Drive access expired. Reconnect this source.")
    }

    override fun open(uri: Uri, size: Long): RemoteHandle {
        val file = try { resolver.openAssetFileDescriptor(uri, "r") }
        catch (_: SecurityException) { throw GoogleDriveDocumentsException("Google Drive access expired. Reconnect this source.") }
        catch (_: IOException) { throw GoogleDriveDocumentsException("Google Drive could not open this file.") }
            ?: throw GoogleDriveDocumentsException("Google Drive could not open this file.")
        return object : DriveDocumentHandle {
            override val length: Long = file.length.takeIf { it >= 0 } ?: size

            override fun stream(position: Long, authorize: () -> Unit): InputStream {
                authorize()
                val input = file.createInputStream()
                try {
                    var remaining = position
                    var seekable = true
                    while (remaining > 0 && seekable) {
                        authorize()
                        val skipped = try { input.skip(remaining) } catch (_: IOException) { 0L }
                        authorize()
                        if (skipped > 0) remaining -= skipped else seekable = false
                    }
                    if (remaining > 0) {
                        // Some cloud DocumentsProviders expose a pipe. Discard forward in
                        // bounded chunks while checking the household epoch before each read.
                        val discard = ByteArray(64 * 1024)
                        while (remaining > 0) {
                            authorize()
                            val count = input.read(discard, 0, minOf(remaining, discard.size.toLong()).toInt())
                            authorize()
                            if (count <= 0) throw GoogleDriveDocumentsException("The Google Drive file ended during seeking.")
                            remaining -= count
                        }
                    }
                    authorize()
                    return input
                } catch (error: Exception) {
                    runCatching { input.close() }
                    throw error
                }
            }

            override fun close() = file.close()
        }
    }
}
