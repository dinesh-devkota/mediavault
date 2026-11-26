package com.dineshdevkota.cinevault.smb

import com.dineshdevkota.cinevault.core.SubtitleSidecars
import com.dineshdevkota.cinevault.core.RemoteFile
import com.dineshdevkota.cinevault.core.VideoFile
import com.dineshdevkota.cinevault.core.MediaFile
import com.dineshdevkota.cinevault.core.ScanExclusions
import com.dineshdevkota.cinevault.core.NasAddress
import com.hierynomus.msdtyp.AccessMask
import com.hierynomus.msfscc.FileAttributes
import com.hierynomus.mssmb2.SMB2CreateDisposition
import com.hierynomus.mssmb2.SMB2ShareAccess
import com.hierynomus.mssmb2.SMBApiException
import com.hierynomus.protocol.commons.EnumWithValue.EnumUtils
import com.hierynomus.security.bc.BCSecurityProvider
import com.hierynomus.smbj.SMBClient
import com.hierynomus.smbj.SmbConfig
import com.hierynomus.smbj.auth.AuthenticationContext
import com.hierynomus.smbj.connection.Connection
import com.hierynomus.smbj.session.Session
import com.hierynomus.smbj.share.DiskShare
import com.hierynomus.smbj.share.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.Closeable
import com.dineshdevkota.cinevault.cloud.GOOGLE_DRIVE_DOCUMENTS
import com.dineshdevkota.cinevault.cloud.GoogleDriveDocuments
import java.io.IOException
import java.io.InputStream
import java.util.EnumSet
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.coroutineContext

/** Snapshot of a source's connection settings (with the decrypted password) used off the main thread. */
data class SourceConfig(
    val id: String,
    val host: String,
    val port: Int?,
    val share: String,
    val rootPath: String,
    val username: String,
    val password: String,
    val ignoredFolders: List<String> = emptyList(),
    val ignoredFiles: List<String> = emptyList(),
    val sourceType: String = "smb",
    val allowInsecureHttp: Boolean = false,
) {
    init { require(sourceType in setOf("smb", "webdav", GOOGLE_DRIVE_DOCUMENTS)) { "Unsupported source type." } }
    val isWebDav: Boolean get() = sourceType == "webdav"
    val isGoogleDrive: Boolean get() = sourceType == GOOGLE_DRIVE_DOCUMENTS
    val caseSensitivePaths: Boolean get() = isWebDav || isGoogleDrive
    override fun toString(): String = "SourceConfig(id=$id, host=${runCatching { NasAddress.parse(host, port).host }.getOrDefault("invalid")}, share=$share)"
}

class SmbException(message: String) : IOException(message)

/** An open NAS file. Close it to release the SMB handle. */
interface RemoteHandle : Closeable {
    val length: Long
    fun stream(position: Long): InputStream
}

private class SmbRemoteHandle(
    private val file: File,
    override val length: Long,
    private val session: Closeable,
) : RemoteHandle {
    private val closed = AtomicBoolean()
    /** Read-ahead stream starting at [position]; skipping only moves the offset, so seeking is cheap. */
    override fun stream(position: Long): InputStream = file.inputStream.also { if (position > 0) it.skip(position) }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        try { file.close() } finally { session.close() }
    }
}

/**
 * Owns one authenticated SMB session/share per source config, reconnecting when the NAS drops idle
 * sessions. Mirrors the tvOS SMBService.
 */
class SmbService(
    private val client: SMBClient = SMBClient(
        SmbConfig.builder()
            .withSecurityProvider(BCSecurityProvider())
            .withTimeout(30, TimeUnit.SECONDS)
            .withSoTimeout(60, TimeUnit.SECONDS)
            .withReadBufferSize(1024 * 1024)
            .build(),
    ),
    private val driveDocuments: GoogleDriveDocuments? = null,
) {
    private fun drive() = checkNotNull(driveDocuments) { "Google Drive is unavailable on this device." }
    private val webdav = com.dineshdevkota.cinevault.webdav.WebDavMedia()

    private class Connected(val connection: Connection, val session: Session, val share: DiskShare) {
        fun close() {
            runCatching { share.close() }
            runCatching { session.close() }
            // SMBClient.connect() leases its cached connection. Session.close() only logs off.
            runCatching { connection.close() }
        }
    }

    private val sessions = SmbSessionCache<SourceConfig, Connected>(
        sourceId = { it.id }, isValid = { it.share.isConnected }, connect = ::connect, disconnect = Connected::close,
    )

    private fun connect(config: SourceConfig): Connected {
        val address = NasAddress.parse(config.host, config.port)
        val connection = client.connect(address.host, address.port ?: SMBClient.DEFAULT_PORT)
        val contexts = if (config.username.isEmpty()) {
            listOf(AuthenticationContext.guest(), AuthenticationContext.anonymous())
        } else {
            val (domain, user) = splitDomain(config.username)
            listOf(AuthenticationContext(user, config.password.toCharArray(), domain))
        }
        var failure: Exception? = null
        for (context in contexts) {
            var session: Session? = null
            try {
                session = connection.authenticate(context)
                val share = session.connectShare(config.share.trim('/', '\\')) as? DiskShare
                    ?: throw SmbException("\"${config.share}\" is not a file share.")
                return Connected(connection, session, share)
            } catch (e: Exception) {
                runCatching { session?.close() }
                if (failure == null) failure = e
            }
        }
        runCatching { connection.close() }
        throw failure ?: SmbException("Could not connect to ${config.host}.")
    }

    private fun <T> withSessionBlocking(
        config: SourceConfig,
        closeInvalidResult: (T) -> Unit = {},
        body: (SessionLease<Connected>) -> T,
    ): T {
        val operation = sessions.operation(config)
        for (attempt in 0..1) {
            val lease = operation.acquire()
            try {
                val result = body(lease)
                try { operation.checkCurrent() } catch (e: SourceResetException) {
                    closeInvalidResult(result)
                    throw e
                }
                return result
            } catch (e: Exception) {
                if (e is kotlinx.coroutines.CancellationException) throw e
                operation.checkCurrent()
                if (attempt == 1 || !isStaleSession(e)) throw e
                operation.invalidate(lease)
            } finally { lease.close() }
        }
        error("Unreachable SMB retry")
    }

    /** Retries a stale session once, unless a source reset invalidated the captured settings. */
    fun <T> withShareBlocking(config: SourceConfig, body: (DiskShare) -> T): T =
        withSessionBlocking(config) { body(it.value.share) }

    suspend fun <T> withShare(config: SourceConfig, body: suspend (DiskShare) -> T): T {
        val operation = sessions.operation(config)
        return withContext(Dispatchers.IO) {
            for (attempt in 0..1) {
                coroutineContext.ensureActive()
                val lease = operation.acquire()
                try {
                    // Setup may block; cancellation during it must not start another NAS operation.
                    coroutineContext.ensureActive()
                    val result = body(lease.value.share)
                    coroutineContext.ensureActive()
                    operation.checkCurrent()
                    return@withContext result
                } catch (e: Exception) {
                    if (e is kotlinx.coroutines.CancellationException) throw e
                    operation.checkCurrent()
                    if (attempt == 1 || !isStaleSession(e)) throw e
                    operation.invalidate(lease)
                } finally { lease.close() }
            }
            error("Unreachable SMB retry")
        }
    }

    /** Invalidates pending results/retries immediately; active file readers keep a cleanup lease. */
    suspend fun reset(sourceId: String) = withContext(Dispatchers.IO) { sessions.reset(sourceId); webdav.service.reset(sourceId) }

    suspend fun testConnection(config: SourceConfig) {
        reset(config.id)
        if (config.isWebDav) { webdav.service.list(config); return }
        if (config.isGoogleDrive) {
            withContext(Dispatchers.IO) { drive().verify(com.dineshdevkota.cinevault.cloud.DriveDocumentGrant.decode(config.password)) }
            return
        }
        withShare(config) { share -> share.list(rootOf(config)) }
    }

    /** Recursively lists indexable video files below the source's root folder. */
    suspend fun scanVideos(config: SourceConfig): List<RemoteFile> =
        if (config.isGoogleDrive) drive().scan(config) {}.filter { VideoFile.isVideo(it.path) }
        else if (config.isWebDav) webdav.scan(config) {}.filter { VideoFile.shouldIndex(it.path, it.size) } else withShare(config) { share ->
        val results = mutableListOf<RemoteFile>()
        val pending = mutableListOf(rootOf(config))
        while (pending.isNotEmpty()) {
            coroutineContext.ensureActive()
            val dir = pending.removeAt(pending.lastIndex)
            if (ScanExclusions.isDirectoryExcluded(dir, config.rootPath, config.ignoredFolders)) continue
            for (entry in share.list(dir)) {
                val name = entry.fileName
                if (name == "." || name == "..") continue
                val path = if (dir.isEmpty()) name else "$dir/$name"
                if (EnumUtils.isSet(entry.fileAttributes, FileAttributes.FILE_ATTRIBUTE_DIRECTORY)) {
                    if (!VideoFile.shouldSkipDirectory(name) && !MediaFile.shouldSkipDirectory(name) &&
                        !ScanExclusions.isDirectoryExcluded(path, config.rootPath, config.ignoredFolders)) pending += path
                } else if (VideoFile.shouldIndex(path, entry.endOfFile) && MediaFile.shouldIndex(path, entry.endOfFile) &&
                    !ScanExclusions.isFileExcluded(path, config.rootPath, config.ignoredFolders, config.ignoredFiles) &&
                    acceptsContent(share, path)) {
                    results += RemoteFile(path, entry.endOfFile)
                }
            }
        }
        results
    }

    /** Reports discovered files in batches while walking every nested media directory. */
    suspend fun scanMedia(config: SourceConfig, onProgress: suspend (ScanProgress) -> Unit): List<RemoteFile> =
        if (config.isGoogleDrive) drive().scan(config, onProgress)
        else if (config.isWebDav) webdav.scan(config, onProgress) else withShare(config) { share ->
        val results = mutableListOf<RemoteFile>()
        val pending = mutableListOf(rootOf(config))
        var folders = 0
        while (pending.isNotEmpty()) {
            coroutineContext.ensureActive()
            val dir = pending.removeAt(pending.lastIndex)
            if (ScanExclusions.isDirectoryExcluded(dir, config.rootPath, config.ignoredFolders)) continue
            val batch = mutableListOf<RemoteFile>()
            for (entry in share.list(dir)) {
                coroutineContext.ensureActive()
                val name = entry.fileName
                if (name == "." || name == "..") continue
                val path = if (dir.isEmpty()) name else "$dir/$name"
                if (EnumUtils.isSet(entry.fileAttributes, FileAttributes.FILE_ATTRIBUTE_DIRECTORY)) {
                    if (!MediaFile.shouldSkipDirectory(name) &&
                        !ScanExclusions.isDirectoryExcluded(path, config.rootPath, config.ignoredFolders)) pending += path
                } else if (MediaFile.shouldIndex(path, entry.endOfFile) &&
                    !ScanExclusions.isFileExcluded(path, config.rootPath, config.ignoredFolders, config.ignoredFiles) &&
                    acceptsContent(share, path)) {
                    val file = RemoteFile(path, entry.endOfFile)
                    results += file
                    batch += file
                    if (batch.size >= 100) {
                        onProgress(ScanProgress(batch.toList(), results.size, folders))
                        batch.clear()
                    }
                }
            }
            onProgress(ScanProgress(batch.toList(), results.size, ++folders))
        }
        results
    }

    /** Read-only, bounded lookup beside the video; never enumerates another folder or share. */
    suspend fun readSubtitleSidecars(
        config: SourceConfig, videoPath: String, preferredLanguage: String? = null, authorize: () -> Unit = {},
    ): SubtitleDiscovery =
        if (config.isGoogleDrive) drive().subtitles(config, videoPath, preferredLanguage, authorize)
        else if (config.isWebDav) webdav.subtitles(config, videoPath, preferredLanguage) else withShare(config) { share ->
        if (!SubtitleSidecars.includesPath(videoPath, config.rootPath, config.ignoredFolders, config.ignoredFiles))
            return@withShare SubtitleDiscovery(emptyList())
        var truncated = false
        val directory = videoPath.replace('\\', '/').substringBeforeLast('/', "")
        val candidates = share.openDirectory(directory, EnumSet.of(AccessMask.FILE_LIST_DIRECTORY), null,
            SMB2ShareAccess.ALL, SMB2CreateDisposition.FILE_OPEN, null).use { folder ->
            val entries = folder.iterator()
            buildList {
                var visited = 0
                while (visited < SubtitleSidecars.MAX_DIRECTORY_ENTRIES && entries.hasNext()) {
                    coroutineContext.ensureActive()
                    visited++
                    val entry = entries.next()
                    if (EnumUtils.isSet(entry.fileAttributes, FileAttributes.FILE_ATTRIBUTE_DIRECTORY)) continue
                    if (entry.endOfFile !in 1L..SubtitleSidecars.MAX_BYTES.toLong()) continue
                    val path = if (directory.isEmpty()) entry.fileName else "$directory/${entry.fileName}"
                    if (!SubtitleSidecars.includesPath(path, config.rootPath, config.ignoredFolders, config.ignoredFiles)) continue
                    SubtitleSidecars.match(videoPath, path)?.let { add(it) }
                }
                truncated = visited >= SubtitleSidecars.MAX_DIRECTORY_ENTRIES && entries.hasNext()
            }
        }
        val selected = candidates.sortedWith(compareByDescending<SubtitleSidecars.Match> {
            it.language?.equals(preferredLanguage, true) == true
        }.thenBy { it.path.lowercase(java.util.Locale.ROOT) }).take(SubtitleSidecars.MAX_FILES)
        val files = selected.mapNotNull { match ->
            coroutineContext.ensureActive()
            try {
                share.openFile(match.path, EnumSet.of(AccessMask.GENERIC_READ), null, SMB2ShareAccess.ALL,
                    SMB2CreateDisposition.FILE_OPEN, null).use { file ->
                    val size = file.fileInformation.standardInformation.endOfFile
                    if (size !in 1L..SubtitleSidecars.MAX_BYTES.toLong()) return@use null
                    val bytes = ByteArray(size.toInt())
                    var offset = 0
                    while (offset < bytes.size) {
                        coroutineContext.ensureActive()
                        val count = file.read(bytes, offset.toLong(), offset, bytes.size - offset)
                        if (count <= 0) return@use null
                        offset += count
                    }
                    SubtitleFile(match, bytes)
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) { null } // A missing or unreadable sidecar never prevents video playback.
        }
        SubtitleDiscovery(files, truncated || candidates.size > SubtitleSidecars.MAX_FILES)
    }

    /** Checks legacy playback candidates with the same bounded probe used while scanning. */
    suspend fun hasPlayableContent(config: SourceConfig, path: String): Boolean {
        if (!MediaFile.isPlayable(path)) return false
        if (!MediaFile.requiresContentCheck(path)) return true
        if (config.isWebDav) return webdav.accepts(config, path, playback = true)
        if (config.isGoogleDrive) return drive().accepts(config, path, playback = true)
        return withShare(config) { acceptsContent(it, path, playback = true) }
    }

    /** TypeScript shares the .ts suffix. Only read a small prefix for this ambiguous extension. */
    private suspend fun acceptsContent(share: DiskShare, path: String, playback: Boolean = false): Boolean {
        if (!MediaFile.requiresContentCheck(path)) return true
        coroutineContext.ensureActive()
        return share.openFile(path, EnumSet.of(AccessMask.GENERIC_READ), null, SMB2ShareAccess.ALL,
            SMB2CreateDisposition.FILE_OPEN, null).use { file ->
            val prefix = ByteArray(1024)
            var read = 0
            while (read < prefix.size) {
                coroutineContext.ensureActive()
                val count = file.read(prefix, read.toLong(), read, prefix.size - read)
                if (count <= 0) break
                read += count
            }
            val bytes = prefix.copyOf(read)
            if (playback) MediaFile.isPlayableTransportStream(bytes) else MediaFile.isTransportStream(bytes)
        }
    }

    /** Opens a file for streaming. Blocking; call from a background thread. */
    fun open(config: SourceConfig, path: String): RemoteHandle =
        if (config.isGoogleDrive) drive().open(config, path)
        else if (config.isWebDav) webdav.service.open(config, path) else withSessionBlocking(
        config, closeInvalidResult = { handle: RemoteHandle -> runCatching { handle.close() } },
    ) { lease ->
        val file = lease.value.share.openFile(
            path,
            EnumSet.of(AccessMask.GENERIC_READ),
            null,
            SMB2ShareAccess.ALL,
            SMB2CreateDisposition.FILE_OPEN,
            null,
        )
        val length = runCatching { file.fileInformation.standardInformation.endOfFile }.getOrElse {
            file.close()
            throw it
        }
        if (length <= 0) {
            file.close()
            throw SmbException("The NAS file is empty or its size could not be read.")
        }
        SmbRemoteHandle(file, length, lease.retain())
    }

    companion object {
        /** Session-level failures where reconnecting can help; other NT statuses (not found, denied) are final. */
        private val staleStatuses = setOf(
            0xC000035CL, // STATUS_NETWORK_SESSION_EXPIRED
            0xC0000203L, // STATUS_USER_SESSION_DELETED
            0xC00000C9L, // STATUS_NETWORK_NAME_DELETED
            0xC0000128L, // STATUS_FILE_CLOSED
        )

        fun isStaleSession(e: Exception): Boolean {
            val chain = generateSequence<Throwable>(e) { it.cause }.take(8).toList()
            if (chain.any { it is kotlinx.coroutines.CancellationException || it is SmbException || it is SourceResetException }) return false
            chain.firstNotNullOfOrNull { it as? SMBApiException }?.let { return it.statusCode in staleStatuses }
            return chain.any { it is IOException }
        }

        fun normalizedHost(raw: String): String = NasAddress.parse(raw).host

        /** Only sign-in/access failures should prompt for credentials; timeouts keep the current form. */
        fun isAuthenticationFailure(error: Throwable): Boolean =
            generateSequence(error) { it.cause }.take(8).any {
                (it is com.dineshdevkota.cinevault.webdav.WebDavException && it.status in setOf(401, 403)) || it is SMBApiException && it.statusCode in setOf(0xC000006DL, 0xC000006AL, 0xC0000022L)
            }

        /** "DOMAIN\\user" becomes (DOMAIN, user). */
        fun splitDomain(username: String): Pair<String?, String> = when {
            '\\' in username -> username.substringBefore('\\') to username.substringAfter('\\')
            else -> null to username
        }

        /** User-facing message for SMB and network failures. */
        fun describe(error: Throwable): String {
            val chain = generateSequence(error) { it.cause }.take(8).toList()
            chain.filterIsInstance<com.dineshdevkota.cinevault.webdav.WebDavException>().firstOrNull()?.let { return it.message ?: "Could not open WebDAV." }
            chain.firstNotNullOfOrNull { it as? SMBApiException }?.let { api ->
                when (api.statusCode) {
                    0xC000006DL -> return "The NAS rejected the user name or password."
                    0xC0000022L -> return "Access denied. Check the account's permissions on the share."
                    0xC00000CCL -> return "Share not found on the NAS. Check the share name."
                    0xC0000034L, 0xC000003AL -> return "Folder or file not found on the NAS."
                }
            }
            if (chain.any { it is java.net.UnknownHostException }) return "Could not find the NAS. Check the server address."
            if (chain.any { it is java.net.ConnectException || it is java.net.SocketTimeoutException }) {
                return "Could not reach the NAS. Check that it is on and on the same network."
            }
            return error.message ?: error.javaClass.simpleName
        }

        fun rootOf(config: SourceConfig): String =
            config.rootPath.replace('\\', '/').split('/').filter { it.isNotEmpty() }.joinToString("/")
    }
}

data class ScanProgress(val files: List<RemoteFile>, val found: Int, val folders: Int)

data class SubtitleFile(val match: SubtitleSidecars.Match, val bytes: ByteArray)

data class SubtitleDiscovery(val files: List<SubtitleFile>, val truncated: Boolean = false)
