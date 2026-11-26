package com.dineshdevkota.cinevault.data

import androidx.room.withTransaction
import com.dineshdevkota.cinevault.cloud.ONEDRIVE
import com.dineshdevkota.cinevault.core.ScanExclusions
import com.dineshdevkota.cinevault.webdav.DavAddress
import java.util.Locale

/** Save the rule change and hide indexed exclusions together, without deleting history. */
suspend fun CineVaultDatabase.saveSourceWithExclusions(source: SourceEntity, authorize: () -> Unit = {}) {
    val caseSensitive = source.sourceType in setOf("webdav", ONEDRIVE)
    fun normalize(paths: List<String>, folder: Boolean): List<String> = paths.map { path ->
        val normalized = when {
            caseSensitive -> path.takeIf { DavAddress.contains(it, "") }
            folder -> ScanExclusions.normalizeFolder(path)
            else -> ScanExclusions.normalizeFile(path)
        }
        requireNotNull(normalized) { "Enter a path relative to the media folder." }
    }.distinctBy { if (caseSensitive) it else it.lowercase(Locale.ROOT) }

    val folders = normalize(source.ignoredFolders, folder = true)
    val files = normalize(source.ignoredFiles, folder = false)
    val saved = source.copy(ignoredFolders = folders, ignoredFiles = files)
    withTransaction {
        authorize()
        sources().upsert(saved)
        if (folders.isNotEmpty() || files.isNotEmpty()) {
            movies().forSource(saved.id).filter {
                ScanExclusions.isFileExcluded(it.filePath, saved.rootPath, folders, files, caseSensitive = caseSensitive)
            }.forEach { movies().markMissing(it.id) }
        }
    }
}
