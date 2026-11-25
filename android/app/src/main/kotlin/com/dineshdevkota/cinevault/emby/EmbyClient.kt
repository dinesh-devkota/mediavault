package com.dineshdevkota.cinevault.emby

import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runInterruptible
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Response
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

class EmbyException(message: String, val status: Int? = null) : IOException(message)

class EmbyClient internal constructor(
    endpoint: String,
    private val deviceId: String,
    version: String,
    private val http: OkHttpClient,
    allowLoopbackHttp: Boolean = false,
) {
    constructor(endpoint: String, deviceId: String, version: String) :
        this(endpoint, deviceId, version, defaultClient)
    @Serializable
    data class User(val Id: String, val Name: String)

    @Serializable
    class Account(val AccessToken: String, val User: User)

    @Serializable
    data class Item(
        val Id: String, val Name: String, val Type: String,
        val SeriesId: String? = null, val SeasonId: String? = null,
        val ParentIndexNumber: Int? = null, val IndexNumber: Int? = null,
        val Overview: String? = null, val OfficialRating: String? = null,
        val ImageTags: Map<String, String>? = null,
    )

    @Serializable
    private data class Page(val Items: List<Item>, val TotalRecordCount: Int? = null)

    @Serializable
    private data class PlaybackInfo(
        @SerialName("PlaySessionId") val sessionId: String? = null,
        @SerialName("MediaSources") val sources: List<MediaSource> = emptyList(),
    )

    @Serializable
    private data class MediaSource(
        @SerialName("Id") val id: String? = null,
        @SerialName("SupportsDirectPlay") val supportsDirectPlay: Boolean = false,
        @SerialName("Container") val container: String? = null,
    )

    class DirectPlayback internal constructor(
        internal val owner: EmbyClient,
        internal val account: Account,
        internal val itemId: String,
        internal val mediaSourceId: String,
        internal val sessionId: String,
        val container: String,
    )

    data class ByteRange(val bytes: ByteArray, val totalLength: Long)

    enum class PlaybackEvent(internal val path: List<String>) {
        STARTED(listOf("Sessions", "Playing")),
        PROGRESS(listOf("Sessions", "Playing", "Progress")),
        STOPPED(listOf("Sessions", "Playing", "Stopped")),
    }

    private val base = requireNotNull(endpoint.trim().toHttpUrlOrNull()?.takeIf {
        (it.isHttps || (allowLoopbackHttp && it.host == "127.0.0.1")) && it.username.isEmpty() && it.password.isEmpty() && it.query == null && it.fragment == null
    }) { "Enter the complete HTTPS address for your Emby server." }
    private val authorization: String

    init {
        require(headerValue(deviceId) && headerValue(version))
        require(!http.followRedirects && !http.followSslRedirects)
        authorization = """Emby Client="MediaVault", Device="Android TV", DeviceId="$deviceId", Version="$version""""
    }

    suspend fun signIn(username: String, password: String): Account {
        val body = json.encodeToString(mapOf("Username" to username, "Pw" to password))
        val session = json.decodeFromString<Account>(send(listOf("Users", "AuthenticateByName"), body = body))
        if (!headerValue(session.AccessToken) || !headerValue(session.User.Id)) throw EmbyException("Invalid Emby sign-in response.")
        return session
    }

    suspend fun libraries(account: Account): List<Item> =
        json.decodeFromString<Page>(send(listOf("Users", account.User.Id, "Views"), account)).Items

    suspend fun catalog(account: Account, libraryId: String, onPage: suspend (List<Item>) -> Unit) {
        val seen = mutableSetOf<String>()
        var offset = 0
        while (offset < 250_000) {
            val page = json.decodeFromString<Page>(send(listOf("Users", account.User.Id, "Items"), account, mapOf(
                "ParentId" to libraryId, "Recursive" to "true", "EnableUserData" to "false",
                "IncludeItemTypes" to "Movie,Series,Season,Episode,Audio,Photo", "Fields" to "Overview",
                "SortBy" to "SortName", "StartIndex" to offset.toString(), "Limit" to "100",
            )))
            if (page.Items.size > 100 || page.Items.any { it.Id.isBlank() || !seen.add(it.Id) }) invalidCatalog()
            if (page.Items.isEmpty()) {
                if ((page.TotalRecordCount ?: offset) > offset) invalidCatalog()
                return
            }
            onPage(page.Items)
            offset += page.Items.size
            if (page.TotalRecordCount?.let { offset >= it } ?: (page.Items.size < 100)) return
        }
        invalidCatalog()
    }

    suspend fun signOut(account: Account) {
        send(listOf("Sessions", "Logout"), account, body = "")
    }

    suspend fun directPlayback(account: Account, itemId: String, containers: Set<String>): DirectPlayback {
        require(headerValue(itemId))
        val info = json.decodeFromString<PlaybackInfo>(send(
            path = listOf("Items", itemId, "PlaybackInfo"),
            account = account,
            query = mapOf("UserId" to account.User.Id),
        ))
        val sessionId = info.sessionId?.takeIf(::headerValue)
            ?: throw EmbyException("Emby did not return a playback session.")
        val media = info.sources.firstOrNull { source ->
            source.supportsDirectPlay && source.container?.lowercase() in containers &&
                source.id?.let(::headerValue) == true
        } ?: throw EmbyException("Emby did not offer a compatible direct-play source.")
        return DirectPlayback(this, account, itemId, requireNotNull(media.id), sessionId, requireNotNull(media.container))
    }

    suspend fun read(account: Account, playback: DirectPlayback, offset: Long, length: Int): ByteRange {
        require(playback.owner === this && playback.account === account)
        require(offset >= 0 && length in 1..maximumBytes && offset <= Long.MAX_VALUE - length)
        val end = offset + length - 1
        val request = request(
            path = listOf("Videos", playback.itemId, "stream"),
            account = account,
            query = mapOf("Static" to "true", "MediaSourceId" to playback.mediaSourceId,
                "PlaySessionId" to playback.sessionId, "DeviceId" to deviceId),
        ).header("Range", "bytes=$offset-$end").header("Accept-Encoding", "identity").build()

        return execute(request) { response ->
            if (response.code != 206) throw EmbyException("Emby did not honor the byte-range request.", response.code)
            val prefix = "bytes $offset-$end/"
            val range = response.header("Content-Range")
            val total = range?.takeIf { it.startsWith(prefix) }?.removePrefix(prefix)?.toLongOrNull()
            val encoding = response.header("Content-Encoding")
            val body = response.body
            if (total == null || total <= end || range != prefix + total ||
                (encoding != null && !encoding.equals("identity", ignoreCase = true)) ||
                body == null || (body.contentLength() >= 0 && body.contentLength() != length.toLong())) {
                throw EmbyException("Emby returned an invalid byte range.")
            }
            val source = body.source()
            if (source.request(length.toLong() + 1)) throw EmbyException("Emby returned too many bytes.")
            val bytes = source.readByteArray()
            if (bytes.size != length) throw EmbyException("Emby ended the byte range early.")
            ByteRange(bytes, total)
        }
    }

    suspend fun report(account: Account, playback: DirectPlayback, event: PlaybackEvent, positionMillis: Long,
                       paused: Boolean = false) {
        require(playback.owner === this && playback.account === account)
        require(positionMillis in 0..Long.MAX_VALUE / 10_000)
        val body = buildJsonObject {
            put("ItemId", playback.itemId)
            put("MediaSourceId", playback.mediaSourceId)
            put("PlaySessionId", playback.sessionId)
            put("PositionTicks", positionMillis * 10_000)
            if (event != PlaybackEvent.STOPPED) {
                put("PlayMethod", "DirectPlay")
                put("CanSeek", true)
                put("IsPaused", paused)
            }
        }
        send(event.path, account, body = body.toString())
    }

    private fun request(path: List<String>, account: Account?, query: Map<String, String> = emptyMap(),
                        body: String? = null): Request.Builder {
        require(path.all(::headerValue))
        val url = base.newBuilder().apply {
            if (base.encodedPath.endsWith("/")) removePathSegment(base.pathSize - 1)
            path.forEach { addPathSegment(it) }
            query.forEach { (name, value) -> addQueryParameter(name, value) }
        }.build()
        val request = Request.Builder().url(url).header("Accept", "application/json")
            .header("Authorization", authorization)
        if (account != null) {
            require(headerValue(account.AccessToken))
            request.header("X-Emby-Token", account.AccessToken)
        }
        if (body != null) request.post(body.toRequestBody("application/json".toMediaType()))
        return request
    }

    private suspend fun send(path: List<String>, account: Account? = null, query: Map<String, String> = emptyMap(),
                             body: String? = null): String =
        execute(request(path, account, query, body).build()) { response ->
            if (!response.isSuccessful) throw EmbyException("Emby returned HTTP ${response.code}.", response.code)
            val source = response.body?.source() ?: return@execute ""
            if (source.request(maximumBytes.toLong() + 1)) throw EmbyException("The Emby response is too large.")
            source.readUtf8()
        }

    private suspend fun <T> execute(request: Request, read: (Response) -> T): T = runInterruptible(Dispatchers.IO) {
        http.newCall(request).execute().use(read)
    }

    private fun invalidCatalog(): Nothing = throw EmbyException("The Emby catalog changed during the scan. Try again.")

    private companion object {
        val json = Json { ignoreUnknownKeys = true }
        const val maximumBytes = 8 * 1024 * 1024
        val defaultClient = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false)
            .callTimeout(30, TimeUnit.SECONDS).build()
        val safeValue = Regex("[A-Za-z0-9_.-]{1,256}")
        fun headerValue(value: String): Boolean = value != "." && value != ".." && safeValue.matches(value)
    }
}
