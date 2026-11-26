package com.dineshdevkota.cinevault.playback

import com.dineshdevkota.cinevault.core.MediaFile
import com.dineshdevkota.cinevault.core.ScanExclusions
import com.dineshdevkota.cinevault.webdav.DavAddress
import com.dineshdevkota.cinevault.core.SubtitleSidecars
import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.smb.SmbException
import com.dineshdevkota.cinevault.smb.SourceConfig
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** Playback entry checks also protect old library rows created before stricter scan rules. */
object PlaybackValidator {
    fun rejectionReason(movie: MovieEntity, config: SourceConfig? = null): String? = when {
        !MediaFile.isPlayable(movie.filePath) -> "This file type is not supported for playback on Android."
        movie.isMissing || movie.isHidden -> "This file is unavailable or ignored. Check the source settings and rescan before playing."
        config != null && !includes(config, movie.filePath) -> "This file is ignored by its source settings. Include it and rescan before playing."
        else -> null
    }

    private fun includes(config: SourceConfig, path: String): Boolean =
        if (config.caseSensitivePaths) {
            DavAddress.contains(path, config.rootPath) &&
                !ScanExclusions.isFileExcluded(path, config.rootPath, config.ignoredFolders, config.ignoredFiles, caseSensitive = true)
        } else {
            SubtitleSidecars.includesPath(path, config.rootPath, config.ignoredFolders, config.ignoredFiles)
        }

    suspend fun validate(movie: MovieEntity, config: SourceConfig, checkContent: suspend (SourceConfig, String) -> Boolean) {
        currentCoroutineContext().ensureActive()
        rejectionReason(movie, config)?.let { throw SmbException(it) }
        if (MediaFile.requiresContentCheck(movie.filePath)) {
            val valid = checkContent(config, movie.filePath)
            currentCoroutineContext().ensureActive()
            if (!valid) throw SmbException("This .ts file is not a supported MPEG transport stream. It may be source code or an unsupported media format.")
        }
    }
}
