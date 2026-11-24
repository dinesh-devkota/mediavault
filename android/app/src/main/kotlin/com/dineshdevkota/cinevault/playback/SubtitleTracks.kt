@file:OptIn(UnstableApi::class)

package com.dineshdevkota.cinevault.playback

import android.net.Uri
import android.util.Base64
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.TrackSelectionParameters
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.util.UnstableApi
import androidx.media3.extractor.text.DefaultSubtitleParserFactory
import androidx.media3.extractor.text.SubtitleParser
import com.dineshdevkota.cinevault.core.SubtitleSidecars
import com.dineshdevkota.cinevault.smb.SubtitleFile

/** Optional captions are decoded and validated before joining the video source. */
internal object SubtitleTracks {
    fun configuration(file: SubtitleFile): MediaItem.SubtitleConfiguration? = configuration(
        file.bytes, file.match.mimeType, file.match.language, file.match.label, file.match.path,
        file.match.forced, file.match.hearingImpaired,
    )

    fun configuration(bytes: ByteArray, mimeType: String, language: String?, label: String, id: String,
                      forced: Boolean = false, hearingImpaired: Boolean = false): MediaItem.SubtitleConfiguration? = runCatching {
        if (bytes.isEmpty() || bytes.size > SubtitleSidecars.MAX_BYTES) return null
        val normalized = if (bytes.size >= 2 && ((bytes[0] == 0xff.toByte() && bytes[1] == 0xfe.toByte()) ||
                (bytes[0] == 0xfe.toByte() && bytes[1] == 0xff.toByte()))) {
            String(bytes, Charsets.UTF_16).toByteArray(Charsets.UTF_8)
        } else bytes
        val parser = DefaultSubtitleParserFactory().create(Format.Builder().setSampleMimeType(mimeType).build())
        var hasCues = false
        parser.parse(normalized, SubtitleParser.OutputOptions.allCues()) { if (it.cues.isNotEmpty()) hasCues = true }
        if (!hasCues) return null
        MediaItem.SubtitleConfiguration.Builder(Uri.parse("data:$mimeType;base64," + Base64.encodeToString(normalized, Base64.NO_WRAP)))
            .setId(id).setMimeType(mimeType).setLanguage(language).setLabel(label)
            .setSelectionFlags(if (forced) C.SELECTION_FLAG_FORCED else 0)
            .setRoleFlags(if (hearingImpaired) C.ROLE_FLAG_CAPTION or C.ROLE_FLAG_DESCRIBES_MUSIC_AND_SOUND else C.ROLE_FLAG_SUBTITLE)
            .build()
    }.getOrNull()

    fun selectById(parameters: TrackSelectionParameters, tracks: Tracks, id: String): TrackSelectionParameters? {
        tracks.groups.filter { it.type == C.TRACK_TYPE_TEXT }.forEach { group ->
            for (index in 0 until group.length) {
                if (group.getTrackFormat(index).id == id && group.isTrackSupported(index)) {
                    return parameters.buildUpon().setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
                        .setOverrideForType(TrackSelectionOverride(group.mediaTrackGroup, index)).build()
                }
            }
        }
        return null
    }

    fun sameLanguage(first: String?, second: String): Boolean = first != null && runCatching {
        val available = java.util.Locale.forLanguageTag(first)
        val preferred = java.util.Locale.forLanguageTag(second)
        available.isO3Language == preferred.isO3Language &&
            (available.country.isEmpty() || preferred.country.isEmpty() || available.country == preferred.country) &&
            (available.script.isEmpty() || preferred.script.isEmpty() || available.script == preferred.script)
    }.getOrDefault(first.equals(second, true))

    fun exactRelease(fileName: String, release: String): Boolean {
        val stem = fileName.substringBeforeLast('.')
        return release.equals(fileName, true) || release.equals(stem, true)
    }

    fun applyPreference(parameters: TrackSelectionParameters, preference: String?): TrackSelectionParameters {
        if (preference == null) return parameters
        return parameters.buildUpon().clearOverridesOfType(C.TRACK_TYPE_TEXT)
            .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, preference == "off")
            .setIgnoredTextSelectionFlags(0)
            .setPreferredTextLanguage(preference.takeUnless { it == "off" || it == "und" })
            .setSelectUndeterminedTextLanguage(preference == "und")
            .build()
    }

    /** Media3's native None button clears overrides/sets these flags; selecting a track adds an override. */
    fun explicitPreference(parameters: TrackSelectionParameters): String? {
        val override = parameters.overrides.values.firstOrNull { it.type == C.TRACK_TYPE_TEXT && it.trackIndices.isNotEmpty() }
        if (override != null) return override.mediaTrackGroup.getFormat(override.trackIndices.first()).language?.takeIf(String::isNotBlank) ?: "und"
        if (C.TRACK_TYPE_TEXT in parameters.disabledTrackTypes ||
            parameters.ignoredTextSelectionFlags == C.SELECTION_FLAG_FORCED.inv()) return "off"
        return null
    }
}
