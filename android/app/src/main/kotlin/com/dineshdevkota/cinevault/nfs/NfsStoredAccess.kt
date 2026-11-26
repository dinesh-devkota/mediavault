package com.dineshdevkota.cinevault.nfs

import com.dineshdevkota.cinevault.core.MediaFile
import com.dineshdevkota.cinevault.core.SubtitleSidecars
import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.family.FamilyPolicy
import com.dineshdevkota.cinevault.family.FamilySession
import com.dineshdevkota.cinevault.smb.SourceConfig
import com.dineshdevkota.cinevault.webdav.DavAddress

internal enum class NfsAccessPurpose { DIRECTORY, FILE, SUBTITLES }

internal data class NfsViewer(val session: FamilySession, val authenticationEpoch: Long)

/** A lease matches one persisted connection and one unlocked local household session. */
internal class NfsStoredAccess(
    private val enabled: () -> Boolean,
    private val viewer: () -> NfsViewer,
    private val source: suspend (String) -> SourceConfig?,
    private val items: suspend (String, String) -> List<MovieEntity>,
) {
    suspend fun authorize(config: SourceConfig, target: String, purpose: NfsAccessPurpose): (String) -> Unit {
        val lease = viewer()
        fun requireCurrent() {
            if (!enabled() || !lease.session.unlocked || lease != viewer()) {
                throw SecurityException("Unlock to read this NFS source.")
            }
        }

        requireCurrent()
        if (config != source(config.id)) throw SecurityException("The NFS source changed. Reopen the item.")
        requireCurrent()
        if (lease.session.admin) return { requireCurrent() }

        val profile = checkNotNull(lease.session.profile)
        val exactGrants = profile.copy(folders = profile.folders.filter { it.caseSensitive && it.sourceId == config.id })
        if (purpose == NfsAccessPurpose.DIRECTORY || exactGrants.folders.isEmpty()) denied()
        val allowed = items(config.id, target).any { item ->
            val requestedItem = item.filePath == target
            val requestedArtwork = purpose == NfsAccessPurpose.FILE && MediaFile.isPhoto(target) &&
                (target == item.localPosterPath || target == item.localBackdropPath || target == item.localSeasonPosterPath) &&
                exactGrants.folders.any { DavAddress.contains(target, it.path) }
            item.sourceId == config.id && !item.isMissing && !item.isHidden && (requestedItem || requestedArtwork) &&
                FamilyPolicy.allows(exactGrants, item)
        }
        if (!allowed) denied()
        requireCurrent()
        val parent = target.substringBeforeLast('/', "")
        return { path ->
            requireCurrent()
            val matchingSubtitle = purpose == NfsAccessPurpose.SUBTITLES &&
                (path == parent || SubtitleSidecars.match(target, path, caseSensitive = true) != null)
            if (path != target && !matchingSubtitle) denied()
        }
    }

    private fun denied(): Nothing = throw SecurityException("This NFS item is unavailable for this profile.")
}
