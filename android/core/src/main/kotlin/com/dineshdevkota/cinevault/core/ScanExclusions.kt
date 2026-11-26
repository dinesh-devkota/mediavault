package com.dineshdevkota.cinevault.core

import java.util.Locale

/** Literal ignored folders, relative to a source's selected scan root. Never changes remote files. */
object ScanExclusions {
    private val absoluteScheme = Regex("^[A-Za-z][A-Za-z0-9+.-]*:")

    /** Canonical display/storage form, or null for an unsafe or root-wide rule. */
    fun normalizeFolder(path: String): String? = components(path, allowRoot = false)?.joinToString("/")

    /** Canonical relative filename, with the same validation as a folder rule. */
    fun normalizeFile(path: String): String? = components(path, allowRoot = false)?.joinToString("/")

    /** [path] is share-relative. Call before listing a directory's children. */
    fun isDirectoryExcluded(path: String, rootPath: String, ignoredFolders: List<String>,
                            caseSensitive: Boolean = false): Boolean =
        matches(components(path, allowRoot = true, caseSensitive), rootPath, ignoredFolders, caseSensitive)

    /** Folder rules match parents; file rules match only the exact relative filename. */
    fun isFileExcluded(path: String, rootPath: String, ignoredFolders: List<String>,
                       ignoredFiles: List<String> = emptyList(), caseSensitive: Boolean = false): Boolean {
        val file = components(path, allowRoot = false, caseSensitive) ?: return false
        if (matches(file.dropLast(1), rootPath, ignoredFolders, caseSensitive)) return true
        val root = components(rootPath, allowRoot = true, caseSensitive) ?: return false
        if (!startsWith(file, root, caseSensitive)) return false
        val relative = file.drop(root.size)
        return ignoredFiles.any { rule ->
            val ignored = components(rule, allowRoot = false, caseSensitive) ?: return@any false
            relative.size == ignored.size && startsWith(relative, ignored, caseSensitive)
        }
    }

    private fun matches(directory: List<String>?, rootPath: String, rules: List<String>, caseSensitive: Boolean): Boolean {
        if (directory == null || rules.isEmpty()) return false
        val root = components(rootPath, allowRoot = true, caseSensitive) ?: return false
        if (!startsWith(directory, root, caseSensitive)) return false
        val relative = directory.drop(root.size)
        return rules.any { rule ->
            val ignored = components(rule, allowRoot = false, caseSensitive) ?: return@any false
            startsWith(relative, ignored, caseSensitive)
        }
    }

    private fun startsWith(path: List<String>, prefix: List<String>, caseSensitive: Boolean): Boolean =
        path.size >= prefix.size && prefix.indices.all {
            if (caseSensitive) path[it] == prefix[it]
            else path[it].lowercase(Locale.ROOT) == prefix[it].lowercase(Locale.ROOT)
        }

    private fun components(path: String, allowRoot: Boolean, caseSensitive: Boolean = false): List<String>? {
        if (caseSensitive) {
            if (path.isEmpty()) return if (allowRoot) emptyList() else null
            return path.split('/').takeIf { parts -> parts.all { it.isNotEmpty() && it != "." && it != ".." } }
        }
        val slashed = path.trim().replace('\\', '/')
        val stripped = slashed.trim('/')
        // A single leading separator is a convenience; UNC hosts and URI/drive paths are not relative.
        if (stripped.isNotBlank() && slashed.startsWith("//")) return null
        if (absoluteScheme.containsMatchIn(stripped) || stripped.contains("://")) return null
        val parts = stripped.split('/').map(String::trim).filter(String::isNotEmpty)
        if (parts.isEmpty()) return if (allowRoot) emptyList() else null
        if (absoluteScheme.containsMatchIn(parts.joinToString("/"))) return null
        if (parts.any { it == "." || it == ".." || it.any { char -> char.code < 32 || char.code in 127..159 } }) return null
        // Wildcards otherwise remain literal: "Extras*" cannot match "Extras" or "Extras 2".
        if (parts.all { part -> part.all { it == '*' || it == '?' } }) return null
        return parts
    }
}
