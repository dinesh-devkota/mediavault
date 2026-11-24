package com.dineshdevkota.cinevault.core

import java.util.Locale

/** Same-folder sidecars only. Exact stems avoid silently borrowing another episode's captions. */
object SubtitleSidecars {
    const val MAX_DIRECTORY_ENTRIES = 4096
    const val MAX_FILES = 8
    const val MAX_BYTES = 2 * 1024 * 1024

    data class Match(val path: String, val language: String?, val forced: Boolean, val hearingImpaired: Boolean) {
        val mimeType: String get() = if (path.endsWith(".vtt", true)) "text/vtt" else "application/x-subrip"
        val label: String get() = listOfNotNull(
            language?.let { Locale.forLanguageTag(it).getDisplayName(Locale.getDefault()).takeIf(String::isNotBlank) }
                ?: "Unspecified language", "Forced".takeIf { forced }, "SDH".takeIf { hearingImpaired }, "NAS",
        ).joinToString(" · ")
    }

    fun includesPath(path: String, rootPath: String, ignoredFolders: List<String>, ignoredFiles: List<String>): Boolean {
        val file = ScanExclusions.normalizeFile(path) ?: return false
        val root = if (rootPath.isBlank()) "" else ScanExclusions.normalizeFolder(rootPath) ?: return false
        return (root.isEmpty() || file.startsWith("$root/", ignoreCase = true)) &&
            !ScanExclusions.isFileExcluded(file, root, ignoredFolders, ignoredFiles)
    }

    fun match(videoPath: String, subtitlePath: String): Match? {
        val video = ScanExclusions.normalizeFile(videoPath) ?: return null
        val subtitle = ScanExclusions.normalizeFile(subtitlePath) ?: return null
        if (!video.substringBeforeLast('/', "").equals(subtitle.substringBeforeLast('/', ""), true)) return null
        val extension = subtitle.substringAfterLast('.', "").lowercase(Locale.ROOT)
        if (extension !in setOf("srt", "vtt")) return null
        val stem = video.substringAfterLast('/').substringBeforeLast('.')
        val candidate = subtitle.substringAfterLast('/').substringBeforeLast('.')
        if (!candidate.startsWith(stem, true)) return null
        val suffix = candidate.drop(stem.length)
        if (suffix.isNotEmpty() && suffix.first() !in ". _-") return null
        val tokens = suffix.trim('.', ' ', '_', '-').split(Regex("[. _]+"))
            .filter(String::isNotEmpty).map { it.lowercase(Locale.ROOT) }
        var language: String? = null
        var forced = false
        var hearingImpaired = false
        for (token in tokens) {
            when (token) {
                "forced" -> forced = true
                "sdh", "cc" -> hearingImpaired = true
                else -> {
                    if (language != null) return null
                    language = normalizeLanguage(token) ?: return null
                }
            }
        }
        return Match(subtitle, language, forced, hearingImpaired)
    }

    private val languages by lazy {
        Locale.getISOLanguages().flatMap { code ->
            val locale = Locale.forLanguageTag(code)
            listOf(code to code, locale.isO3Language to code)
        }.toMap() + mapOf("fre" to "fr", "ger" to "de", "dut" to "nl", "chi" to "zh", "cze" to "cs",
            "gre" to "el", "rum" to "ro", "wel" to "cy", "slo" to "sk", "per" to "fa")
    }

    /** Canonical ISO/BCP-47 form for sidecars, embedded tracks and online searches. */
    fun normalizeLanguage(token: String): String? {
        val normalized = token.trim().lowercase(Locale.ROOT).replace('_', '-')
        // Android's ICU locale list includes und, unlike the desktop JVM's ISO list.
        if (normalized == "off" || normalized == "und") return null
        val parts = normalized.split('-')
        val base = languages[parts.first()] ?: return null
        if (parts.drop(1).any { !it.matches(Regex("[a-z]{2}|[a-z]{4}|[0-9]{3}")) }) return null
        return Locale.forLanguageTag((listOf(base) + parts.drop(1)).joinToString("-")).toLanguageTag()
    }
}
