package com.dineshdevkota.cinevault.photos

import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.data.SourceEntity
import com.dineshdevkota.cinevault.jellyfin.JELLYFIN
import com.dineshdevkota.cinevault.jellyfin.jellyfinPhotoID
import java.util.Locale

data class PhotoAlbum(
    val id: String, val sourceId: String, val folder: String, val photos: List<MovieEntity>,
    val title: String = folder.substringAfterLast('/').ifBlank { "Shared folder" },
)

fun photoAlbumId(photo: MovieEntity): String = "${photo.sourceId}:${photo.filePath.replace('\\', '/').substringBeforeLast('/', "") }"

/** Photos from different NAS sources are never merged just because their folder names match. */
fun photoAvailable(photo: MovieEntity, source: SourceEntity?): Boolean {
    if (source == null || !photo.isPhoto || photo.isHidden || photo.isMissing) return false
    return if (source.sourceType == JELLYFIN) jellyfinPhotoID(photo.filePath) != null
        else source.includesFile(photo.filePath)
}

fun photoAlbums(items: List<MovieEntity>, sources: List<SourceEntity>? = null): List<PhotoAlbum> {
    val sourceById = sources?.associateBy { it.id }
    return items.asSequence()
    .filter { it.isPhoto && !it.isHidden && !it.isMissing && (sourceById == null || photoAvailable(it, sourceById[it.sourceId])) }
    .groupBy(::photoAlbumId)
    .map { (id, photos) ->
        val first = photos.first()
        val folder = first.filePath.replace('\\', '/').substringBeforeLast('/', "")
        val library = sourceById?.get(first.sourceId)?.takeIf { it.sourceType == JELLYFIN }
        PhotoAlbum(id, first.sourceId, folder,
            photos.sortedWith(compareBy<MovieEntity> { it.fileName.lowercase(Locale.ROOT) }.thenBy { it.id }),
            title = library?.name ?: folder.substringAfterLast('/').ifBlank { "Shared folder" })
    }.sortedWith(compareBy<PhotoAlbum> { it.title.lowercase(Locale.ROOT) }.thenBy { it.sourceId }.thenBy { it.folder })
}
