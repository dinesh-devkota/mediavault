package com.dineshdevkota.cinevault.nfs

import java.io.IOException
import java.nio.charset.CharacterCodingException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

internal data class NfsDirectoryEntry(val name: String, val directory: Boolean, val size: Long)

/** An explicitly mounted, read-only NFSv3 export. One session serializes its native handle. */
internal class NfsSession private constructor(private var handle: Long) {
    private val lock = Any()

    suspend fun list(path: String = ""): List<NfsDirectoryEntry> = onNativeContext { mounted ->
        NativeNfs.list(mounted, path.encodeToByteArray()).mapNotNull { entry ->
            val name = try {
                entry.name.decodeToString(throwOnInvalidSequence = true)
            } catch (_: CharacterCodingException) {
                return@mapNotNull null
            }
            NfsDirectoryEntry(name, entry.directory, entry.size)
        }
    }

    suspend fun read(path: String, offset: Long, length: Int): ByteArray = onNativeContext {
        NativeNfs.read(it, path.encodeToByteArray(), offset, length)
    }

    suspend fun disconnect() = withContext(NonCancellable + Dispatchers.IO) {
        synchronized(lock) {
            if (handle != 0L) {
                NativeNfs.disconnect(handle)
                handle = 0L
            }
        }
    }

    private suspend fun <T> onNativeContext(operation: (Long) -> T): T = withContext(Dispatchers.IO) {
        synchronized(lock) {
            check(handle != 0L) { "The NFS export is disconnected." }
            operation(handle)
        }
    }

    companion object {
        fun hasNativeLibrary(): Boolean = NativeNfs.available

        suspend fun connect(host: String, export: String, mountPort: Int = 0, nfsPort: Int = 0): NfsSession {
            if (!hasNativeLibrary()) throw IOException("NFS is unavailable in this build.")
            var pending: NfsSession? = null
            try {
                return withContext(Dispatchers.IO) {
                    val handle = NativeNfs.connect(host.encodeToByteArray(), export.encodeToByteArray(), mountPort, nfsPort)
                    check(handle != 0L) { "The NFS client did not return a connection." }
                    NfsSession(handle).also { pending = it }
                }
            } catch (error: Exception) {
                pending?.disconnect()
                throw error
            }
        }
    }
}

private object NativeNfs {
    val available = try {
        System.loadLibrary("mediavaultnfs")
        true
    } catch (_: LinkageError) {
        false
    } catch (_: SecurityException) {
        false
    }

    class Entry(val name: ByteArray, val directory: Boolean, val size: Long)

    external fun connect(host: ByteArray, export: ByteArray, mountPort: Int, nfsPort: Int): Long
    external fun disconnect(handle: Long)
    external fun list(handle: Long, path: ByteArray): Array<Entry>
    external fun read(handle: Long, path: ByteArray, offset: Long, length: Int): ByteArray
}
