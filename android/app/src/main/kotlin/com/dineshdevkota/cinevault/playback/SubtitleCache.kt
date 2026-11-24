package com.dineshdevkota.cinevault.playback

import android.content.Context
import com.dineshdevkota.cinevault.core.SubtitleSidecars
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.security.MessageDigest

/** Bounded, disposable app cache. Credentials and NAS paths are never written here. */
internal class SubtitleCache(context: Context) {
    private val directory = File(context.cacheDir, "subtitles")
    suspend fun read(key: String): ByteArray? = withContext(Dispatchers.IO) {
        runCatching {
            val file = file(key)
            if (!file.isFile || file.length() !in 1L..SubtitleSidecars.MAX_BYTES.toLong()) null
            else file.readBytes().also { file.setLastModified(System.currentTimeMillis()) }
        }.getOrNull()
    }
    suspend fun write(key: String, bytes: ByteArray) = withContext(Dispatchers.IO) {
        if (bytes.size !in 1..SubtitleSidecars.MAX_BYTES) return@withContext
        runCatching {
            directory.mkdirs()
            file(key).writeBytes(bytes)
            directory.listFiles()?.filter { it.isFile }?.sortedByDescending { it.lastModified() }
                ?.drop(24)?.forEach { it.delete() }
        }
        Unit
    }
    private fun file(key: String): File {
        val name = MessageDigest.getInstance("SHA-256").digest(key.toByteArray()).joinToString("") { "%02x".format(it) }
        return File(directory, name)
    }
}
