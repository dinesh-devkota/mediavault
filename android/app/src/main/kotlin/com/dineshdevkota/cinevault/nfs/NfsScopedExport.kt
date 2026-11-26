package com.dineshdevkota.cinevault.nfs

import com.dineshdevkota.cinevault.core.ScanExclusions
import com.dineshdevkota.cinevault.smb.NasEntry
import com.dineshdevkota.cinevault.smb.RemoteHandle
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.nio.charset.CharacterCodingException
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.runBlocking

/**
 * Restricts a mounted NFSv3 export to a selected folder. The authorization check must bind the
 * current source and viewer session, and throw SecurityException for a denied path.
 */
internal class NfsScopedExport(
    private val rootPath: String,
    private val ignoredFolders: List<String>,
    private val ignoredFiles: List<String>,
    private val authorize: (String) -> Unit,
    private val listEntries: suspend (String) -> List<NfsDirectoryEntry>,
    private val readRange: suspend (String, Long, Int) -> ByteArray,
) {
    init {
        require(validPath(rootPath, allowRoot = true)) { "Invalid NFS media folder." }
        require((ignoredFolders + ignoredFiles).all { validPath(it, allowRoot = false) }) { "Invalid NFS ignore rule." }
    }

    suspend fun list(path: String): List<NasEntry> =
        entries(path).map { NasEntry(it.name, it.directory) }

    suspend fun entries(path: String): List<NfsDirectoryEntry> {
        requireIncluded(path, directory = true)
        val entries = exactDirectory(path, permissionPath = path).mapNotNull { entry ->
            if (!validComponent(entry.name)) return@mapNotNull null
            val child = if (path.isEmpty()) entry.name else "$path/${entry.name}"
            if (!included(child, entry.directory)) return@mapNotNull null
            try {
                authorize(child)
                entry
            } catch (_: SecurityException) { null }
        }
        authorize(path)
        return entries
    }

    /** Return a blocking reader for the shared Media3/photo entry points. */
    fun open(path: String): RemoteHandle {
        requireIncluded(path, directory = false)
        val folder = path.substringBeforeLast('/', "")
        val name = path.substringAfterLast('/')
        // Resolve the known file via its parent with exact case. Never return sibling metadata.
        val file = runBlocking { exactDirectory(folder, permissionPath = path) }.singleOrNull { it.name == name }
        authorize(path)
        if (file == null || file.directory || file.size <= 0) throw IOException("The NFS file is unavailable.")
        return object : RemoteHandle {
            private val closed = AtomicBoolean()
            override val length = file.size

            private fun checkHandle() {
                if (closed.get()) throw IOException("The NFS file is closed.")
                authorize(path)
            }

            override fun stream(position: Long): InputStream {
                require(position in 0..length) { "Invalid NFS stream position." }
                checkHandle()
                return object : InputStream() {
                    private val streamClosed = AtomicBoolean()
                    private var next = position

                    override fun read(): Int {
                        val byte = ByteArray(1)
                        return if (read(byte, 0, 1) == -1) -1 else byte[0].toInt() and 255
                    }

                    override fun read(output: ByteArray, offset: Int, count: Int): Int {
                        if (offset < 0 || count < 0 || offset > output.size - count) throw IndexOutOfBoundsException()
                        checkStream()
                        if (count == 0) return 0
                        if (next == length) return -1
                        val request = minOf(length - next, count.toLong(), MAX_READ_BYTES).toInt()
                        val received = runBlocking { readRange(path, next, request) }
                        checkStream()
                        if (received.size != request) throw EOFException("The NFS server returned a short read.")
                        received.copyInto(output, offset)
                        next += request
                        return request
                    }

                    private fun checkStream() {
                        if (streamClosed.get()) throw IOException("The NFS stream is closed.")
                        checkHandle()
                    }

                    override fun close() { streamClosed.set(true) }
                }
            }

            override fun close() { closed.set(true) }
        }
    }

    private suspend fun exactDirectory(path: String, permissionPath: String): List<NfsDirectoryEntry> {
        suspend fun guardedList(directory: String): List<NfsDirectoryEntry> {
            authorize(permissionPath)
            val entries = listEntries(directory)
            authorize(permissionPath)
            return entries
        }
        var current = rootPath
        var entries = guardedList(current)
        val relative = path.removePrefix(rootPath).removePrefix("/")
        if (relative.isEmpty()) return entries
        for (component in relative.split('/')) {
            // Servers backed by case-insensitive storage may accept another spelling on lookup.
            if (entries.singleOrNull { it.name == component }?.directory != true) {
                throw IOException("The NFS directory is unavailable.")
            }
            current = if (current.isEmpty()) component else "$current/$component"
            entries = guardedList(current)
        }
        return entries
    }

    private fun requireIncluded(path: String, directory: Boolean) {
        if (!included(path, directory)) throw SecurityException("This path is outside the selected NFS media folder.")
    }

    private fun included(path: String, directory: Boolean): Boolean {
        if (!validPath(path, allowRoot = directory)) return false
        if (rootPath.isNotEmpty() && !path.startsWith("$rootPath/") && !(directory && path == rootPath)) return false
        return if (directory) !ScanExclusions.isDirectoryExcluded(path, rootPath, ignoredFolders, caseSensitive = true)
        else !ScanExclusions.isFileExcluded(path, rootPath, ignoredFolders, ignoredFiles, caseSensitive = true)
    }

    private companion object {
        const val MAX_READ_BYTES = 512L * 1024

        fun validComponent(value: String) =
            value.isNotEmpty() && value != "." && value != ".." &&
                value.none { it == '/' || it == '\\' || it.code < 32 || it.code == 127 } && utf8Bytes(value) in 1..255

        fun validPath(value: String, allowRoot: Boolean): Boolean =
            if (value.isEmpty()) allowRoot
            else utf8Bytes(value) in 1..4095 && value.split('/').all(::validComponent)

        fun utf8Bytes(value: String): Int =
            if (value.length > 4095) -1 else try {
                value.encodeToByteArray(throwOnInvalidSequence = true).size
            } catch (_: CharacterCodingException) { -1 }
    }
}

/** The caller owns this session and supplies an authorization check for its current source and viewer. */
internal fun NfsSession.scope(
    rootPath: String,
    ignoredFolders: List<String> = emptyList(),
    ignoredFiles: List<String> = emptyList(),
    authorize: (String) -> Unit,
) = NfsScopedExport(rootPath, ignoredFolders, ignoredFiles, authorize, ::list, ::read)
