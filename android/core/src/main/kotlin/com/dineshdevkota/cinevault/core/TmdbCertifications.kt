package com.dineshdevkota.cinevault.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable data class TmdbRelease(val certification: String = "")
@Serializable data class TmdbReleaseCountry(@SerialName("iso_3166_1") val country: String = "",
    @SerialName("release_dates") val releases: List<TmdbRelease> = emptyList())
@Serializable data class TmdbReleaseDates(val results: List<TmdbReleaseCountry> = emptyList()) {
    // Different releases may have different cuts; use the strictest known US certification.
    val usRating: String? get() = strictest(results.filter { it.country == "US" }.flatMap { it.releases }.map { it.certification },
        listOf("G", "PG", "PG-13", "R", "NC-17"))
}
@Serializable data class TmdbContentRating(@SerialName("iso_3166_1") val country: String = "", val rating: String = "")
@Serializable data class TmdbContentRatings(val results: List<TmdbContentRating> = emptyList()) {
    val usRating: String? get() = strictest(results.filter { it.country == "US" }.map { it.rating },
        listOf("TV-Y", "TV-G", "TV-Y7", "TV-PG", "TV-14", "TV-MA"))
}
private fun strictest(values: List<String>, order: List<String>): String? {
    val nonempty = values.map { if (it.trim() == "TV-Y7-FV") "TV-Y7" else it.trim() }.filter(String::isNotEmpty)
    if (nonempty.any { it !in order }) return null
    return nonempty.maxByOrNull(order::indexOf)
}
