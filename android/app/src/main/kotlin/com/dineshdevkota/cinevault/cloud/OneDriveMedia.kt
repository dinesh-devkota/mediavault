package com.dineshdevkota.cinevault.cloud

import com.dineshdevkota.cinevault.core.MediaFile
import com.dineshdevkota.cinevault.core.RemoteFile
import com.dineshdevkota.cinevault.core.ScanExclusions
import com.dineshdevkota.cinevault.core.SubtitleSidecars
import com.dineshdevkota.cinevault.smb.FileSourceTransport
import com.dineshdevkota.cinevault.smb.NasEntry
import com.dineshdevkota.cinevault.smb.RemoteHandle
import com.dineshdevkota.cinevault.smb.ScanProgress
import com.dineshdevkota.cinevault.smb.SourceConfig
import com.dineshdevkota.cinevault.smb.SubtitleDiscovery
import com.dineshdevkota.cinevault.smb.SubtitleFile
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.runBlocking
import java.io.IOException
import java.io.InputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

internal const val ONEDRIVE = "onedrive"

internal fun isOneDriveFileName(name: String): Boolean =
    name.isNotBlank() && name != "." && name != ".." &&
        name.none { it in "\\/:*<>?|" || it.isISOControl() }

private fun String.oneDriveParts(): List<String> {
    if (isEmpty()) return emptyList()
    return split('/').takeIf { path -> path.size <= 128 && path.all(::isOneDriveFileName) }
        ?: throw CloudClientException("The OneDrive path is invalid.")
}

/** Stable Graph drive/item IDs are resolved from the saved folder and exact path before each open. */
internal class OneDriveMedia(
    private val store: OneDriveAccountStore,
    private val client: (String) -> OneDriveClient = { OneDriveClient(it) },
) : FileSourceTransport {
    private class Connection(val application: String, val account: OneDriveAccount)

    private val accounts = ConcurrentHashMap<UUID, Connection>()

    fun account(source: UUID, publicClientId: String): OneDriveAccount {
        val application = UUID.fromString(publicClientId).toString()
        require(application.equals(publicClientId, ignoreCase = true)) { "Enter a Microsoft Entra application ID." }
        val connection = accounts.computeIfAbsent(source) { Connection(application, OneDriveAccount(source, client(application), store)) }
        check(connection.application == application) { "The Microsoft application ID changed. Start a new connection." }
        return connection.account
    }

    private fun account(config: SourceConfig) = account(UUID.fromString(config.id), config.host)

    /** Only unsaved setup sources use this. Saved sources stay bound to one in-memory revision. */
    suspend fun discardDraft(source: UUID) {
        accounts.remove(source)?.account?.cancelLink()
    }

    suspend fun disconnect(source: UUID, publicClientId: String) = account(source, publicClientId).disconnect()

    suspend fun childFolders(account: OneDriveAccount, parent: String?, version: Long): List<OneDriveClient.Entry> =
        entries(account, parent, version).filter { it.folder != null && !MediaFile.shouldSkipDirectory(it.name) }
            .distinctBy { it.id }.sortedBy { it.name.lowercase(java.util.Locale.ROOT) }

    suspend fun childFolders(config: SourceConfig, path: String): List<String> =
        listEntries(config, path).filter { it.isDirectory }.map { it.name }

    suspend fun listEntries(config: SourceConfig, path: String): List<NasEntry> {
        val account = account(config)
        val version = account.connectionVersion()
        val parent = folder(account, version, config.share.ifBlank { null }, path.oneDriveParts())
        return entries(account, parent, version)
            .filter { (it.folder == null || !MediaFile.shouldSkipDirectory(it.name)) && (it.folder != null || it.file != null) }
            .map { NasEntry(it.name, it.folder != null) }
            .distinct()
            .sortedWith(compareByDescending<NasEntry> { it.isDirectory }.thenBy { it.name.lowercase(java.util.Locale.ROOT) })
    }

    override suspend fun testConnection(config: SourceConfig) {
        val account = account(config)
        val version = account.connectionVersion()
        account.list(config.share.ifBlank { null }, version) { currentCoroutineContext().ensureActive() }
    }

    override suspend fun scan(config: SourceConfig, onProgress: suspend (ScanProgress) -> Unit): List<RemoteFile> {
        val collected = mutableListOf<RemoteFile>()
        val catalog = OneDriveCatalog(
            account(config), config.share.ifBlank { null },
            mayBrowse = { path -> path.isEmpty() || !ScanExclusions.isDirectoryExcluded(
                path.joinToString("/"), "", config.ignoredFolders, caseSensitive = true,
            ) },
            mayRead = { path -> includes(config, path.joinToString("/")) },
        )
        // Commit the completed catalogue as a single scanner result. A partial or revoked scan
        // never marks previously indexed items missing.
        catalog.scan { file -> collected.add(RemoteFile(file.path.joinToString("/"), file.size)) }
        return collected
    }

    override suspend fun hasPlayableContent(config: SourceConfig, path: String): Boolean {
        if (!includes(config, path) || !MediaFile.isPlayable(path)) return false
        if (!MediaFile.requiresContentCheck(path)) return true
        val opened = resolveFile(config, path)
        if (opened.size <= 0) return false
        return MediaFile.isTransportStream(opened.read(0, minOf(opened.size, 1024L).toInt()))
    }

    override fun open(config: SourceConfig, path: String): RemoteHandle = blocking {
        val opened = resolveFile(config, path)
        RangeHandle(opened.size, opened.authorize, opened.read)
    }

    override suspend fun subtitles(config: SourceConfig, path: String, preferredLanguage: String?, authorize: () -> Unit): SubtitleDiscovery {
        authorize()
        if (!includes(config, path)) return SubtitleDiscovery(emptyList())
        val parsed = path.oneDriveParts()
        val parents = parsed.dropLast(1)
        val account = account(config)
        val version = account.connectionVersion()
        val parent = folder(account, version, config.share.ifBlank { null }, parents)
        val siblings = entries(account, parent, version)
        authorize()
        if (siblings.none { it.file != null && it.name == parsed.last() }) return SubtitleDiscovery(emptyList())
        val truncated = siblings.size > SubtitleSidecars.MAX_DIRECTORY_ENTRIES
        val candidates = siblings.take(SubtitleSidecars.MAX_DIRECTORY_ENTRIES).mapNotNull { entry ->
            if (entry.file == null || entry.size == null || entry.size !in 1L..SubtitleSidecars.MAX_BYTES.toLong()) return@mapNotNull null
            val combined = (parents + entry.name).joinToString("/")
            if (!includes(config, combined)) return@mapNotNull null
            SubtitleSidecars.match(path, combined)?.let { it to entry }
        }.sortedWith(compareByDescending<Pair<SubtitleSidecars.Match, OneDriveClient.Entry>> {
            it.first.language?.equals(preferredLanguage, ignoreCase = true) == true
        }.thenBy { it.first.path })
        val files = candidates.take(SubtitleSidecars.MAX_FILES).mapNotNull { (match, entry) ->
            try {
                authorize()
                val size = requireNotNull(entry.size).toInt()
                val bytes = account.read(entry.id, 0, size, version,
                    OneDriveClient.ScopedFile(config.share.ifBlank { null }, parents + entry.name, size.toLong()))
                authorize()
                SubtitleFile(match, bytes)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: IOException) { null }
        }
        return SubtitleDiscovery(files, truncated || candidates.size > SubtitleSidecars.MAX_FILES)
    }

    override suspend fun reset(sourceId: String) {
        val id = runCatching { UUID.fromString(sourceId) }.getOrNull() ?: return
        accounts[id]?.account?.invalidateReads()
    }

    private fun includes(config: SourceConfig, path: String): Boolean =
        path.oneDriveParts().isNotEmpty() && config.rootPath.isEmpty() &&
            !ScanExclusions.isFileExcluded(path, "", config.ignoredFolders, config.ignoredFiles, caseSensitive = true)

    private class OpenedFile(
        val size: Long,
        val authorize: () -> Unit,
        val read: suspend (offset: Long, length: Int) -> ByteArray,
    )

    private suspend fun resolveFile(config: SourceConfig, path: String): OpenedFile {
        if (!includes(config, path)) throw CloudClientException("This OneDrive item is outside the selected folder or ignored.")
        val account = account(config)
        val version = account.connectionVersion()
        val parts = path.oneDriveParts()
        val parent = folder(account, version, config.share.ifBlank { null }, parts.dropLast(1))
        val item = entries(account, parent, version).singleOrNull { it.file != null && it.name == parts.last() }
            ?: throw CloudClientException("This OneDrive item moved or is no longer available. Rescan the source.")
        val size = item.size?.takeIf { it >= 0 }
            ?: throw CloudClientException("Microsoft did not return the size of this file.")
        val within = OneDriveClient.ScopedFile(config.share.ifBlank { null }, parts, size)
        return OpenedFile(size, { account.requireCurrent(version) }) { offset, length ->
            account.read(item.id, offset, length, version, within)
        }
    }

    private suspend fun folder(account: OneDriveAccount, version: Long, root: String?, parts: List<String>): String? {
        var parent = root
        for (name in parts) {
            if (MediaFile.shouldSkipDirectory(name)) throw CloudClientException("This OneDrive folder is unavailable.")
            parent = entries(account, parent, version).singleOrNull { it.folder != null && it.name == name }?.id
                ?: throw CloudClientException("This OneDrive folder moved or is no longer available. Rescan the source.")
        }
        return parent
    }

    private suspend fun entries(account: OneDriveAccount, parent: String?, version: Long): List<OneDriveClient.Entry> {
        val entries = mutableListOf<OneDriveClient.Entry>()
        var count = 0
        account.list(parent, version) { page ->
            count += page.size
            if (count > 50_000) throw CloudClientException("The selected OneDrive folder has too many items.")
            entries.addAll(page.filter { it.remoteItem == null && isOneDriveFileName(it.name) })
        }
        return entries
    }

    private class RangeHandle(
        override val length: Long,
        private val authorize: () -> Unit,
        private val range: suspend (Long, Int) -> ByteArray,
    ) : RemoteHandle {
        private val closed = AtomicBoolean()

        override fun stream(position: Long): InputStream {
            require(position in 0..length)
            return object : InputStream() {
                private var absolute = position
                private var bytes = ByteArray(0)
                private var cursor = 0
                private val single = ByteArray(1)
                private var streamClosed = false

                override fun read(): Int = if (read(single, 0, 1) < 0) -1 else single[0].toInt() and 255

                override fun read(buffer: ByteArray, offset: Int, count: Int): Int {
                    if (offset < 0 || count < 0 || offset > buffer.size - count) throw IndexOutOfBoundsException()
                    if (closed.get() || streamClosed) throw IOException("The OneDrive file was closed.")
                    authorize()
                    if (count == 0) return 0
                    if (absolute >= length) return -1
                    if (cursor == bytes.size) {
                        val requested = minOf((1024 * 1024).toLong(), length - absolute).toInt()
                        bytes = blocking { range(absolute, requested) }
                        cursor = 0
                        if (bytes.size != requested) throw IOException("OneDrive returned an incomplete read.")
                        if (closed.get()) throw IOException("The OneDrive file was closed.")
                    }
                    val available = minOf(count, bytes.size - cursor)
                    authorize()
                    bytes.copyInto(buffer, offset, cursor, cursor + available)
                    cursor += available
                    absolute += available
                    return available
                }

                override fun close() {
                    streamClosed = true
                    bytes = ByteArray(0)
                }
            }
        }

        override fun close() { closed.set(true) }
    }

    private companion object {
        fun <T> blocking(action: suspend () -> T): T = try {
            runBlocking { action() }
        } catch (interrupted: InterruptedException) {
            Thread.currentThread().interrupt()
            throw IOException("OneDrive read stopped.", interrupted)
        }
    }
}
