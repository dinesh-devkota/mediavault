package com.dineshdevkota.cinevault.smb

import com.dineshdevkota.cinevault.core.RemoteFile

/** Browsable, read-only providers that use the shared file scanner and player. */
interface FileSourceTransport {
    suspend fun listEntries(config: SourceConfig): List<NasEntry>
    suspend fun testConnection(config: SourceConfig)
    suspend fun scan(config: SourceConfig, onProgress: suspend (ScanProgress) -> Unit): List<RemoteFile>
    suspend fun hasPlayableContent(config: SourceConfig, path: String): Boolean
    suspend fun subtitles(config: SourceConfig, path: String, preferredLanguage: String?, authorize: () -> Unit): SubtitleDiscovery
    fun open(config: SourceConfig, path: String): RemoteHandle
    suspend fun reset(sourceId: String)
}
