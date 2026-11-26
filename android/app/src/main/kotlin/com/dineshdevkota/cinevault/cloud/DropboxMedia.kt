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
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okhttp3.OkHttpClient
import java.io.IOException
import java.io.InputStream
import java.util.Locale
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

internal const val DROPBOX = "dropbox"

internal object DropboxPath {
    fun isValid(path: String): Boolean =
        path.length in 1..4096 && '\\' !in path && ScanExclusions.normalizeFile(path) == path

    fun contains(path: String, root: String, includeRoot: Boolean = false): Boolean =
        isValid(path) && isValid(root) &&
            (path.startsWith("$root/", ignoreCase = true) || includeRoot && path.equals(root, ignoreCase = true))

    fun child(entry: DropboxClient.Entry, parent: String): String? {
        val path = entry.displayPath?.takeIf { it.startsWith('/') }?.drop(1) ?: return null
        val expected = if (parent.isEmpty()) entry.name else "$parent/${entry.name}"
        return path.takeIf { isValid(it) && '/' !in entry.name && it.equals(expected, ignoreCase = true) }
    }
}

/** Holds a short-lived access token in memory. Only the refresh token is persisted by the editor. */
internal class DropboxAccess(
    private val client: DropboxClient,
    private val refreshToken: String,
    initial: DropboxClient.Credentials? = null,
) {
    private data class Cached(val token: String, val validUntil: Long)
    private val lock = Mutex()
    private var cached = initial?.let(::cache)

    init { require(refreshToken.isNotBlank()) { "Reconnect this Dropbox source." } }

    private fun cache(credential: DropboxClient.Credentials): Cached {
        if (credential.accessToken.isBlank() || credential.expiresIn <= 0) {
            throw CloudClientException("Dropbox did not return a usable access token.")
        }
        return Cached(credential.accessToken,
            System.nanoTime() + TimeUnit.SECONDS.toNanos((credential.expiresIn - 30).coerceAtLeast(0).toLong()))
    }

    private suspend fun token(authorize: () -> Unit, failed: String? = null): String = lock.withLock {
        authorize()
        val previous = cached
        if (previous != null && previous.token != failed && previous.validUntil - System.nanoTime() > 0) {
            return@withLock previous.token
        }
        val refreshed = try { cache(client.refresh(refreshToken)) }
        catch (error: CloudClientException) {
            if (error.statusCode in listOf(400, 401)) {
                throw CloudClientException("Dropbox authorization expired. Reconnect it from Sources.", error.statusCode)
            }
            throw error
        }
        cached = refreshed
        authorize()
        refreshed.token
    }

    suspend fun <T> run(authorize: () -> Unit, operation: suspend (String) -> T): T {
        val access = token(authorize)
        authorize()
        val result = try { operation(access) }
        catch (error: CloudClientException) {
            if (error.statusCode != 401) throw error
            val fresh = token(authorize, failed = access)
            authorize()
            operation(fresh)
        }
        authorize()
        return result
    }
}

/** Dropbox files use the same caller contracts as SMB and WebDAV. */
internal class DropboxMedia(private val fixtureHttp: OkHttpClient? = null) : FileSourceTransport {
    private class Connection(val config: SourceConfig, http: OkHttpClient?) {
        val client = DropboxClient(config.host, http)
        val tokens = DropboxAccess(client, config.password)
        val valid = AtomicBoolean(true)

        suspend fun root(authorize: () -> Unit) {
            val root = tokens.run(authorize) { client.metadata("/${config.rootPath}", it) }
            if (root.kind != "folder" || root.id != config.share ||
                !root.displayPath.equals("/${config.rootPath}", ignoreCase = true)) {
                throw CloudClientException("The selected Dropbox folder moved or was replaced. Reopen Sources.")
            }
        }

        suspend fun file(path: String, authorize: () -> Unit): DropboxClient.Entry {
            val found = tokens.run(authorize) { client.metadata("/$path", it) }
            if (found.kind != "file" || !found.downloadable || !DropboxClient.validId(found.id) ||
                found.size == null || found.size <= 0 || !found.displayPath.equals("/$path", ignoreCase = true)) {
                throw CloudClientException("The Dropbox file is unavailable.")
            }
            return found
        }

        suspend fun entries(path: String, authorize: () -> Unit): List<DropboxClient.Entry> {
            // Accumulate inside the request so a refreshed listing starts at the first page.
            return tokens.run(authorize) { token ->
                val entries = mutableListOf<DropboxClient.Entry>()
                client.listFolder("/$path", token, authorize) { page ->
                    if (entries.size + page.size > MAX_ENTRIES) throw CloudClientException("This Dropbox folder is too large to scan.")
                    entries.addAll(page)
                }
                entries
            }
        }

        suspend fun read(file: DropboxClient.Entry, position: Long, count: Int, authorize: () -> Unit): ByteArray =
            tokens.run(authorize) { client.read(file, position, count, it) }

        fun guard(authorize: () -> Unit): () -> Unit = {
            authorize()
            if (!valid.get()) throw IOException("The Dropbox source changed. Reopen the item.")
        }
    }

    private val connections = mutableMapOf<String, Connection>()

    override suspend fun reset(sourceId: String) {
        synchronized(this) { connections.remove(sourceId)?.valid?.set(false) }
    }

    @Synchronized
    private fun connection(config: SourceConfig): Connection {
        require(config.sourceType == DROPBOX && DropboxClient.validId(config.share) && DropboxPath.isValid(config.rootPath)) {
            "This Dropbox source has an invalid media folder."
        }
        val stored = connections[config.id]
        if (stored != null &&
            stored.config.host == config.host && stored.config.share == config.share &&
            stored.config.username == config.username && stored.config.password == config.password &&
            stored.config.rootPath == config.rootPath) return stored
        stored?.valid?.set(false)
        return Connection(config, fixtureHttp).also { connections[config.id] = it }
    }

    override suspend fun listEntries(config: SourceConfig): List<NasEntry> =
        browse(config, config.rootPath)

    suspend fun browse(config: SourceConfig, path: String, authorize: () -> Unit = {}): List<NasEntry> {
        require(DropboxPath.contains(path, config.rootPath, includeRoot = true))
        val connection = connection(config)
        val guard = connection.guard(authorize)
        connection.root(guard)
        return connection.entries(path, guard).mapNotNull { entry ->
            DropboxPath.child(entry, path)?.let { NasEntry(entry.name, entry.kind == "folder") }
        }.sortedWith(compareByDescending<NasEntry> { it.isDirectory }.thenBy { it.name.lowercase(Locale.ROOT) })
    }

    override suspend fun scan(config: SourceConfig, onProgress: suspend (ScanProgress) -> Unit): List<RemoteFile> {
        val connection = connection(config)
        val authorize = connection.guard {}
        connection.root(authorize)
        val pending = ArrayDeque(listOf(config.rootPath))
        val visited = mutableSetOf<String>()
        val results = mutableListOf<RemoteFile>()
        while (pending.isNotEmpty()) {
            currentCoroutineContext().ensureActive()
            val folder = pending.removeLast()
            if (!visited.add(folder.lowercase(Locale.ROOT))) continue
            if (visited.size > MAX_ENTRIES) throw CloudClientException("Choose a smaller Dropbox media folder.")
            for (entry in connection.entries(folder, authorize)) {
                currentCoroutineContext().ensureActive()
                val path = DropboxPath.child(entry, folder) ?: continue
                if (entry.kind == "folder") {
                    if (!MediaFile.shouldSkipDirectory(entry.name) &&
                        !ScanExclusions.isDirectoryExcluded(path, config.rootPath, config.ignoredFolders)) pending.add(path)
                    continue
                }
                val length = entry.size ?: continue
                if (entry.kind != "file" || !entry.downloadable || !DropboxClient.validId(entry.id) ||
                    !MediaFile.shouldIndex(path, length) || !includes(config, path)) continue
                if (MediaFile.requiresContentCheck(path) &&
                    !MediaFile.isTransportStream(connection.read(entry, 0, minOf(length, 1024).toInt(), authorize))) continue
                results.add(RemoteFile(path, length))
                if (results.size > MAX_ENTRIES) throw CloudClientException("Choose a smaller Dropbox media folder.")
            }
            // Keep this catalog atomic in the shared scanner until the selected folder is revalidated.
            onProgress(ScanProgress(emptyList(), results.size, visited.size))
        }
        // A replacement at the selected path during the catalog walk cannot complete the scan.
        connection.root(authorize)
        return results
    }

    suspend fun accepts(config: SourceConfig, path: String, authorize: () -> Unit): Boolean {
        if (!includes(config, path)) return false
        val connection = connection(config)
        val guard = connection.guard(authorize)
        connection.root(guard)
        val file = connection.file(path, guard)
        return MediaFile.isPlayableTransportStream(connection.read(file, 0, minOf(file.size ?: 0, 1024).toInt(), guard))
    }

    override suspend fun subtitles(
        config: SourceConfig, path: String, preferredLanguage: String?, authorize: () -> Unit,
    ): SubtitleDiscovery {
        val video = path
        if (!includes(config, video)) return SubtitleDiscovery(emptyList())
        val connection = connection(config)
        val guard = connection.guard(authorize)
        connection.root(guard)
        val folder = video.substringBeforeLast('/')
        val entries = connection.entries(folder, guard)
        val matches = entries.take(SubtitleSidecars.MAX_DIRECTORY_ENTRIES).mapNotNull { entry ->
            val path = DropboxPath.child(entry, folder) ?: return@mapNotNull null
            if (entry.kind != "file" || !entry.downloadable || (entry.size ?: 0) !in 1L..SubtitleSidecars.MAX_BYTES.toLong() ||
                !includes(config, path)) return@mapNotNull null
            SubtitleSidecars.match(video, path)?.let { it to entry }
        }.sortedWith(compareByDescending<Pair<SubtitleSidecars.Match, DropboxClient.Entry>> {
            it.first.language?.equals(preferredLanguage, true) == true
        }.thenBy { it.first.path.lowercase(Locale.ROOT) })
        val files = matches.take(SubtitleSidecars.MAX_FILES).mapNotNull { (match, entry) ->
            try {
                val bytes = connection.read(entry, 0, requireNotNull(entry.size).toInt(), guard)
                SubtitleFile(match, bytes)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: CloudClientException) { null }
        }
        return SubtitleDiscovery(
            files, entries.size > SubtitleSidecars.MAX_DIRECTORY_ENTRIES || matches.size > SubtitleSidecars.MAX_FILES)
    }

    override suspend fun testConnection(config: SourceConfig) {
        browse(config, config.rootPath)
    }

    override suspend fun hasPlayableContent(config: SourceConfig, path: String): Boolean =
        MediaFile.isPlayable(path) && (!MediaFile.requiresContentCheck(path) || accepts(config, path) {})

    override fun open(config: SourceConfig, path: String): RemoteHandle = open(config, path) {}

    /** Blocking only at the file-reader boundary, where the existing Media3 data source reads. */
    fun open(config: SourceConfig, path: String, authorize: () -> Unit): RemoteHandle {
        require(includes(config, path)) { "The file is outside the selected Dropbox media folder." }
        val connection = connection(config)
        val guard = connection.guard(authorize)
        val file = runBlocking { connection.root(guard); connection.file(path, guard) }
        return DropboxHandle(requireNotNull(file.size), guard) { start, count ->
            runBlocking { connection.read(file, start, count, guard) }
        }
    }

    private class DropboxHandle(
        override val length: Long,
        private val authorize: () -> Unit,
        private val readRange: (Long, Int) -> ByteArray,
    ) : RemoteHandle {
        private val closed = AtomicBoolean(false)
        override fun close() { closed.set(true) }

        override fun stream(position: Long): InputStream {
            require(position in 0..length)
            return object : InputStream() {
                private var next = position
                private var buffer = ByteArray(0)
                private var index = 0
                private var streamClosed = false

                override fun read(): Int {
                    val one = ByteArray(1)
                    return if (read(one, 0, 1) == -1) -1 else one[0].toInt() and 255
                }

                override fun read(output: ByteArray, offset: Int, count: Int): Int {
                    if (offset < 0 || count < 0 || offset > output.size - count) throw IndexOutOfBoundsException()
                    if (closed.get() || streamClosed) throw IOException("The Dropbox stream is closed.")
                    authorize()
                    if (count == 0) return 0
                    if (next == length) return -1
                    if (index == buffer.size) {
                        buffer = readRange(next, minOf(length - next, CHUNK_BYTES).toInt())
                        index = 0
                    }
                    authorize()
                    if (closed.get() || streamClosed) throw IOException("The Dropbox stream is closed.")
                    val size = minOf(count, buffer.size - index)
                    buffer.copyInto(output, offset, index, index + size)
                    index += size
                    next += size
                    return size
                }

                override fun close() { streamClosed = true; buffer = ByteArray(0) }
            }
        }
    }

    private companion object {
        const val MAX_ENTRIES = 100_000
        const val CHUNK_BYTES = 512L * 1024
        fun includes(config: SourceConfig, path: String) = DropboxPath.contains(path, config.rootPath) &&
            !ScanExclusions.isFileExcluded(path, config.rootPath, config.ignoredFolders, config.ignoredFiles)
    }
}
