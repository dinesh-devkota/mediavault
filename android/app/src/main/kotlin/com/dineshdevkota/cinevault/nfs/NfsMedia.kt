package com.dineshdevkota.cinevault.nfs

import com.dineshdevkota.cinevault.BuildConfig
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
import java.io.DataInputStream
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.runBlocking

internal const val NFS = "nfs"

internal object NfsDevelopment {
    val available: Boolean
        get() = BuildConfig.DEBUG && BuildConfig.NFS_DEVELOPMENT_ENABLED && NfsSession.hasNativeLibrary()

    suspend fun mount(config: SourceConfig): NfsSession {
        if (!available) throw IOException("NFS is unavailable in this build.")
        return NfsSession.connect(config.host, config.share, nfsPort = config.port ?: 0)
    }
}

/** The caller binds authorization to the current source configuration and household session. */
internal class NfsMedia(
    private val authorize: suspend (SourceConfig, String, NfsAccessPurpose) -> (String) -> Unit,
    private val mount: suspend (SourceConfig) -> NfsSession = NfsDevelopment::mount,
) : FileSourceTransport {
    private val generations = ConcurrentHashMap<String, AtomicBoolean>()

    override suspend fun reset(sourceId: String) {
        generations.computeIfPresent(sourceId) { _, current ->
            current.set(false)
            null
        }
    }

    override suspend fun listEntries(config: SourceConfig): List<NasEntry> =
        browse(config, config.rootPath)

    suspend fun browse(config: SourceConfig, path: String): List<NasEntry> =
        withExport(config, path, NfsAccessPurpose.DIRECTORY) { scope -> scope.list(path) }

    override suspend fun testConnection(config: SourceConfig) {
        listEntries(config)
    }

    override suspend fun scan(
        config: SourceConfig,
        onProgress: suspend (ScanProgress) -> Unit,
    ): List<RemoteFile> = withExport(config, config.rootPath, NfsAccessPurpose.DIRECTORY) { scope ->
        val pending = ArrayDeque(listOf(config.rootPath))
        val files = mutableListOf<RemoteFile>()
        var folders = 0
        var entries = 0
        while (pending.isNotEmpty()) {
            currentCoroutineContext().ensureActive()
            val folder = pending.removeLast()
            val children = scope.entries(folder)
            entries += children.size
            if (++folders > MAX_FOLDERS || entries > MAX_ENTRIES) {
                throw IOException("Choose a smaller NFS media folder.")
            }
            for (entry in children) {
                currentCoroutineContext().ensureActive()
                val path = childPath(folder, entry.name)
                if (entry.directory) {
                    if (!MediaFile.shouldSkipDirectory(entry.name)) pending.add(path)
                } else if (MediaFile.shouldIndex(path, entry.size) &&
                    (!MediaFile.requiresContentCheck(path) || MediaFile.isTransportStream(prefix(scope, path)))
                ) {
                    files += RemoteFile(path, entry.size)
                }
            }
            // Commit catalog changes only after the full scan and source authorization succeed.
            onProgress(ScanProgress(emptyList(), files.size, folders))
        }
        files
    }

    override suspend fun hasPlayableContent(config: SourceConfig, path: String): Boolean {
        if (!MediaFile.isPlayable(path)) return false
        return withExport(config, path, NfsAccessPurpose.FILE) { scope ->
            if (MediaFile.requiresContentCheck(path)) {
                MediaFile.isPlayableTransportStream(prefix(scope, path))
            } else {
                scope.open(path).use { it.length > 0 }
            }
        }
    }

    override suspend fun subtitles(
        config: SourceConfig,
        path: String,
        preferredLanguage: String?,
        authorize: () -> Unit,
    ): SubtitleDiscovery = withExport(config, path, NfsAccessPurpose.SUBTITLES, authorize) { scope ->
        scope.open(path).close()
        val folder = path.substringBeforeLast('/', "")
        val children = scope.entries(folder)
        val candidates = children.take(SubtitleSidecars.MAX_DIRECTORY_ENTRIES).mapNotNull { entry ->
            if (entry.directory || entry.size !in 1L..SubtitleSidecars.MAX_BYTES.toLong()) return@mapNotNull null
            SubtitleSidecars.match(path, childPath(folder, entry.name), caseSensitive = true)
        }.sortedWith(compareByDescending<SubtitleSidecars.Match> {
            it.language?.equals(preferredLanguage, ignoreCase = true) == true
        }.thenBy { it.path })
        val files = candidates.take(SubtitleSidecars.MAX_FILES).mapNotNull { match ->
            currentCoroutineContext().ensureActive()
            try {
                scope.open(match.path).use { handle ->
                    if (handle.length !in 1L..SubtitleSidecars.MAX_BYTES.toLong()) return@use null
                    SubtitleFile(match, readExactly(handle, handle.length.toInt()))
                }
            } catch (error: CancellationException) {
                throw error
            } catch (_: IOException) {
                null
            }
        }
        SubtitleDiscovery(files, children.size > SubtitleSidecars.MAX_DIRECTORY_ENTRIES ||
            candidates.size > SubtitleSidecars.MAX_FILES)
    }

    override fun open(config: SourceConfig, path: String): RemoteHandle = runBlocking {
        val check = access(config, path, NfsAccessPurpose.FILE)
        check(path)
        val session = mount(config)
        try {
            val handle = scope(config, session, check).open(path)
            object : RemoteHandle by handle {
                private val closed = AtomicBoolean()

                override fun close() {
                    if (!closed.compareAndSet(false, true)) return
                    try {
                        handle.close()
                    } finally {
                        runBlocking { session.disconnect() }
                    }
                }
            }
        } catch (error: Exception) {
            session.disconnect()
            throw error
        }
    }

    private suspend fun <T> withExport(
        config: SourceConfig,
        path: String,
        purpose: NfsAccessPurpose,
        beforeAccess: () -> Unit = {},
        block: suspend (NfsScopedExport) -> T,
    ): T {
        val sourceAccess = access(config, path, purpose)
        val check: (String) -> Unit = { requested ->
            beforeAccess()
            sourceAccess(requested)
        }
        check(path)
        val session = mount(config)
        return try {
            val result = block(scope(config, session, check))
            check(path)
            result
        } finally {
            session.disconnect()
        }
    }

    private suspend fun access(config: SourceConfig, target: String, purpose: NfsAccessPurpose): (String) -> Unit {
        require(config.sourceType == NFS && config.username.isEmpty() && config.password.isEmpty()) {
            "This NFS source is invalid."
        }
        val current = generations.computeIfAbsent(config.id) { AtomicBoolean(true) }
        val authorized = authorize(config, target, purpose)
        return { path ->
            if (!current.get()) throw SecurityException("The NFS source changed. Reopen the item.")
            authorized(path)
            if (!current.get()) throw SecurityException("The NFS source changed. Reopen the item.")
        }
    }

    private fun scope(config: SourceConfig, session: NfsSession, check: (String) -> Unit) =
        session.scope(config.rootPath, config.ignoredFolders, config.ignoredFiles, check)

    private fun prefix(scope: NfsScopedExport, path: String): ByteArray =
        scope.open(path).use { readExactly(it, minOf(it.length, 1024).toInt()) }

    private fun readExactly(file: RemoteHandle, size: Int): ByteArray =
        DataInputStream(file.stream(0)).use { input -> ByteArray(size).also(input::readFully) }

    private fun childPath(folder: String, name: String): String =
        if (folder.isEmpty()) name else "$folder/$name"

    private companion object {
        const val MAX_FOLDERS = 20_000
        const val MAX_ENTRIES = 200_000
    }
}
