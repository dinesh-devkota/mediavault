package com.dineshdevkota.cinevault.cloud

import com.dineshdevkota.cinevault.core.MediaFile
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** Lists a configured subtree and issues reads only for the entries found under that root. */
internal class OneDriveCatalog(
    private val account: OneDriveAccount,
    private val root: String?,
    private val mayBrowse: (relativePath: List<String>) -> Boolean,
    private val mayRead: (relativePath: List<String>) -> Boolean,
) {
    class File internal constructor(
        val id: String,
        val path: List<String>,
        val size: Long,
        private val readRange: suspend (offset: Long, length: Int) -> ByteArray,
    ) {
        suspend fun read(offset: Long, length: Int): ByteArray {
            require(offset >= 0 && length in 1..MAX_CLOUD_RESPONSE && length.toLong() <= size && offset <= size - length) {
                "The range is outside the OneDrive file."
            }
            return readRange(offset, length)
        }
    }

    private data class Folder(val id: String?, val path: List<String>)

    suspend fun scan(onFile: suspend (File) -> Unit) {
        val version = account.connectionVersion()
        val pending = ArrayDeque<Folder>()
        val visited = mutableSetOf<String>()
        val emitted = mutableSetOf<String>()
        pending.add(Folder(root, emptyList()))
        root?.let { visited.add(it) }
        var entriesSeen = 0
        while (pending.isNotEmpty()) {
            currentCoroutineContext().ensureActive()
            val folder = pending.removeLast()
            if (!mayBrowse(folder.path)) continue
            account.list(folder.id, version) { entries ->
                requireAccess(mayBrowse(folder.path))
                for (entry in entries) {
                    currentCoroutineContext().ensureActive()
                    if (++entriesSeen > 250_000) throw CloudClientException("The selected OneDrive folder is too large.")
                    if (entry.remoteItem != null || !validBaseName(entry.name)) continue
                    val path = folder.path + entry.name
                    if (entry.folder != null) {
                        if (!MediaFile.shouldSkipDirectory(entry.name) && mayBrowse(path) && visited.add(entry.id)) {
                            if (visited.size > 10_000 || path.size > 128) {
                                throw CloudClientException("The selected OneDrive folder is too large.")
                            }
                            pending.add(Folder(entry.id, path))
                        }
                    } else if (entry.file != null && mayRead(path)) {
                        val size = entry.size ?: continue
                        val relative = path.joinToString("/")
                        if (!MediaFile.shouldIndex(relative, size) || entry.id in emitted) continue
                        val protected = path.toList()
                        val file = File(entry.id, path.toList(), size) { offset, length ->
                            requireAccess(mayRead(protected))
                            val bytes = account.read(entry.id, offset, length, version, OneDriveClient.ScopedFile(root, protected, size))
                            requireAccess(mayRead(protected))
                            bytes
                        }
                        if (MediaFile.requiresContentCheck(relative) &&
                            !MediaFile.isTransportStream(file.read(0, minOf(size, 1024L).toInt()))
                        ) continue
                        emitted.add(entry.id)
                        onFile(file)
                    }
                }
            }
        }
    }

    private fun requireAccess(allowed: Boolean) {
        if (!allowed) throw CloudClientException("This profile cannot access the selected OneDrive item.")
    }

    private fun validBaseName(name: String): Boolean = isOneDriveFileName(name)
}
