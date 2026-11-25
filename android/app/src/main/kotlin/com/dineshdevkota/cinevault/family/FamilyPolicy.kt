package com.dineshdevkota.cinevault.family

import com.dineshdevkota.cinevault.core.MediaFile
import com.dineshdevkota.cinevault.core.ScanExclusions
import com.dineshdevkota.cinevault.data.MovieEntity
import kotlinx.serialization.Serializable

@Serializable
data class FolderAccess(val sourceId: String, val path: String)

@Serializable
data class HouseholdProfile(
    val id: String,
    val name: String,
    val pin: PinVerifier? = null,
    val folders: List<FolderAccess> = emptyList(),
    val movieLimit: String? = null,
    val tvLimit: String? = null,
) {
    val isAdmin: Boolean get() = id == ADMIN
    companion object { const val ADMIN = "admin" }
}

object FamilyPolicy {
    val movieRatings = listOf("G", "PG", "PG-13", "R", "NC-17")
    val tvRatings = listOf("TV-Y", "TV-G", "TV-Y7", "TV-PG", "TV-14", "TV-MA")

    fun allows(profile: HouseholdProfile, movie: MovieEntity): Boolean {
        if (profile.isAdmin) return true
        val path = ScanExclusions.normalizeFile(movie.filePath) ?: return false
        val folderAllowed = profile.folders.any { grant ->
            if (grant.sourceId != movie.sourceId) false else {
                val folder = if (grant.path.isEmpty()) "" else ScanExclusions.normalizeFolder(grant.path)
                folder != null && (folder.isEmpty() || path.startsWith("$folder/", ignoreCase = true))
            }
        }
        if (!folderAllowed) return false
        if (movie.isPhoto || MediaFile.isAudio(movie.filePath)) return true
        val television = movie.episodeInfo != null
        val maximum = if (television) profile.tvLimit else profile.movieLimit
        if (maximum == null) return true
        return allowsRating(movie.ageCertification, maximum, television)
    }

    fun allowsRating(rating: String?, maximum: String, television: Boolean): Boolean {
        val ratings = if (television) tvRatings else movieRatings
        val rank = ratings.indexOf(if (rating == "TV-Y7-FV") "TV-Y7" else rating)
        val limit = ratings.indexOf(maximum)
        return rank >= 0 && limit >= 0 && rank <= limit
    }
}
