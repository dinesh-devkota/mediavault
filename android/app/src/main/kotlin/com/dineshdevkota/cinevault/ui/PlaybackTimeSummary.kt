package com.dineshdevkota.cinevault.ui

/** Prefer the duration measured from this file; metadata is only a fallback. */
internal fun remainingPlaybackTime(durationMs: Long, runtimeMinutes: Int?, positionMs: Long): String? {
    val total = durationMs.takeIf { it > 0 }
        ?: runtimeMinutes?.takeIf { it > 0 }?.toLong()?.times(60_000)
        ?: return null
    if (positionMs < 0 || positionMs >= total) return null
    val remaining = total - positionMs
    if (remaining < 60_000) return "Less than a minute left"
    // Round up without overflowing for malformed durations.
    val minutes = remaining / 60_000 + if (remaining % 60_000 == 0L) 0 else 1
    val hours = minutes / 60
    val remainder = minutes % 60
    val durationText = when {
        hours == 0L -> "$minutes min"
        remainder == 0L -> "${hours}h"
        else -> "${hours}h ${remainder}m"
    }
    return "About $durationText left"
}
