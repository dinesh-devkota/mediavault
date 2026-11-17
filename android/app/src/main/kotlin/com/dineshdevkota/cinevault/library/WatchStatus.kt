package com.dineshdevkota.cinevault.library

import com.dineshdevkota.cinevault.core.MediaFile
import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.data.SourceEntity

/** Hidden titles remain editable from the explicit Hidden collection. */
internal fun watchStatusItems(items: List<MovieEntity>, sources: List<SourceEntity>): List<MovieEntity> {
    val sourceById = sources.associateBy { it.id }
    return items.filter {
        !it.isMissing && !it.isPhoto && !MediaFile.isAudio(it.filePath) &&
            sourceById[it.sourceId]?.includesFile(it.filePath) == true
    }.distinctBy { it.id }
}
