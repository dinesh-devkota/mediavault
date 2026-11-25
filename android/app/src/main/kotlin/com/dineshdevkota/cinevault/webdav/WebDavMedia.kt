package com.dineshdevkota.cinevault.webdav

import com.dineshdevkota.cinevault.core.MediaFile
import com.dineshdevkota.cinevault.core.RemoteFile
import com.dineshdevkota.cinevault.core.ScanExclusions
import com.dineshdevkota.cinevault.core.SubtitleSidecars
import com.dineshdevkota.cinevault.smb.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlin.coroutines.coroutineContext

/** The file-provider contract consumed by the existing library, photo and playback paths. */
class WebDavMedia(val service: WebDavService = WebDavService()) {
    suspend fun scan(config: SourceConfig, onProgress: suspend (ScanProgress) -> Unit): List<RemoteFile> {
        val pending = java.util.ArrayDeque<String>().apply { add(config.rootPath) }
        val visited = mutableSetOf<String>(); val results = mutableListOf<RemoteFile>(); var folders = 0
        while (pending.isNotEmpty()) {
            coroutineContext.ensureActive()
            val dir = pending.removeLast()
            if (!visited.add(dir) || ScanExclusions.isDirectoryExcluded(dir, config.rootPath, config.ignoredFolders)) continue
            if (visited.size > 100000) throw WebDavException("This source contains too many folders. Choose a smaller media folder.")
            val batch = mutableListOf<RemoteFile>()
            for (entry in service.list(config, dir)) {
                coroutineContext.ensureActive()
                if (entry.directory) {
                    if (!MediaFile.shouldSkipDirectory(entry.name) && !ScanExclusions.isDirectoryExcluded(entry.path, config.rootPath, config.ignoredFolders)) pending += entry.path
                } else if (MediaFile.shouldIndex(entry.path, entry.size) &&
                    !ScanExclusions.isFileExcluded(entry.path, config.rootPath, config.ignoredFolders, config.ignoredFiles) && accepts(config, entry.path)) {
                    val file = RemoteFile(entry.path, entry.size); results += file; batch += file
                    if (batch.size >= 100) { onProgress(ScanProgress(batch.toList(), results.size, folders)); batch.clear() }
                }
            }
            onProgress(ScanProgress(batch.toList(), results.size, ++folders))
        }
        return results
    }

    suspend fun accepts(config: SourceConfig, path: String, playback: Boolean = false): Boolean {
        if (!MediaFile.requiresContentCheck(path)) return true
        val bytes = read(config, path, 1024, prefix = true)
        return if (playback) MediaFile.isPlayableTransportStream(bytes) else MediaFile.isTransportStream(bytes)
    }

    private suspend fun read(config: SourceConfig, path: String, max: Int, prefix: Boolean = false): ByteArray = withContext(Dispatchers.IO) {
        coroutineContext.ensureActive()
        service.open(config, path).use { handle ->
            if (!prefix && handle.length > max) throw WebDavException("The subtitle file is too large.")
            val bytes = ByteArray(minOf(handle.length, max.toLong()).toInt())
            handle.stream(0).use { stream ->
                var position = 0
                while (position < bytes.size) { coroutineContext.ensureActive(); val count = stream.read(bytes, position, bytes.size - position)
                    if (count <= 0) throw WebDavException("The file ended unexpectedly."); position += count }
            }
            coroutineContext.ensureActive(); bytes
        }
    }

    suspend fun subtitles(config: SourceConfig, videoPath: String, language: String?): SubtitleDiscovery {
        if (!SubtitleSidecars.includesPath(videoPath, config.rootPath, config.ignoredFolders, config.ignoredFiles)) return SubtitleDiscovery(emptyList())
        val entries = service.list(config, videoPath.substringBeforeLast('/', ""))
        val matches = entries.take(SubtitleSidecars.MAX_DIRECTORY_ENTRIES).filter {
            !it.directory && it.size in 1L..SubtitleSidecars.MAX_BYTES.toLong() && SubtitleSidecars.includesPath(it.path, config.rootPath, config.ignoredFolders, config.ignoredFiles)
        }.mapNotNull { SubtitleSidecars.match(videoPath, it.path) }
            .sortedWith(compareByDescending<SubtitleSidecars.Match> { it.language?.equals(language, true) == true }.thenBy { it.path })
        val files = matches.take(SubtitleSidecars.MAX_FILES).mapNotNull { match ->
            try { SubtitleFile(match, read(config, match.path, SubtitleSidecars.MAX_BYTES)) }
            catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
            catch (_: Exception) { null }
        }
        return SubtitleDiscovery(files, matches.size > SubtitleSidecars.MAX_FILES || entries.size > SubtitleSidecars.MAX_DIRECTORY_ENTRIES)
    }
}
