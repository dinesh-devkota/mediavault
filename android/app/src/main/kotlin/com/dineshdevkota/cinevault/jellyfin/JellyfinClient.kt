package com.dineshdevkota.cinevault.jellyfin

import com.dineshdevkota.cinevault.webdav.DavAddress
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.runInterruptible
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.coroutineContext

class JellyfinException(message: String, val status: Int? = null) : IOException(message)

@Serializable
class JellyfinSession(
    @SerialName("AccessToken") val token: String,
    @SerialName("User") val user: JellyfinUser,
)

@Serializable
data class JellyfinUser(@SerialName("Id") val id: String, @SerialName("Name") val name: String)

@Serializable
class JellyfinQuickConnect(
    @SerialName("Secret") val secret: String,
    @SerialName("Code") val code: String,
    @SerialName("Authenticated") val authenticated: Boolean = false,
)

@Serializable
data class JellyfinItem(
    @SerialName("Id") val id: String,
    @SerialName("Name") val name: String,
    @SerialName("Type") val type: String,
    @SerialName("CollectionType") val collectionType: String? = null,
    @SerialName("SeriesId") val seriesId: String? = null,
    @SerialName("SeriesName") val seriesName: String? = null,
    @SerialName("SeasonId") val seasonId: String? = null,
    @SerialName("ParentIndexNumber") val seasonNumber: Int? = null,
    @SerialName("IndexNumber") val indexNumber: Int? = null,
    @SerialName("Overview") val overview: String? = null,
    @SerialName("ProductionYear") val year: Int? = null,
    @SerialName("OfficialRating") val rating: String? = null,
    @SerialName("RunTimeTicks") val runtimeTicks: Long? = null,
    @SerialName("ImageTags") val imageTags: Map<String, String> = emptyMap(),
)

@Serializable
private data class JellyfinPage(
    @SerialName("Items") val items: List<JellyfinItem>,
    @SerialName("TotalRecordCount") val total: Int? = null,
    @SerialName("StartIndex") val start: Int? = null,
)

@Serializable
private data class JellyfinPlaybackInfo(
    @SerialName("MediaSources") val sources: List<JellyfinMediaSource> = emptyList(),
    @SerialName("PlaySessionId") val playSessionId: String? = null,
)

@Serializable
private data class JellyfinMediaSource(
    @SerialName("Id") val id: String,
    @SerialName("SupportsDirectPlay") val directPlay: Boolean = false,
    @SerialName("TranscodingUrl") val transcodingUrl: String? = null,
    @SerialName("MediaStreams") val streams: List<JellyfinStream> = emptyList(),
)

@Serializable
private data class JellyfinStream(
    @SerialName("Type") val type: String? = null,
    @SerialName("Index") val index: Int = -1,
    @SerialName("Codec") val codec: String? = null,
    @SerialName("Language") val language: String? = null,
    @SerialName("IsTextSubtitleStream") val isTextSubtitle: Boolean = false,
    @SerialName("IsForced") val isForced: Boolean = false,
)

class JellyfinPlayback internal constructor(
    val itemId: String,
    val mediaSourceId: String,
    val playSessionId: String,
    val method: String,
    val url: HttpUrl,
    val subtitles: List<JellyfinSubtitle>,
)

data class JellyfinSubtitle(val index: Int, val language: String?, val forced: Boolean, val url: HttpUrl)

enum class JellyfinPlaybackEvent(internal val route: String) {
    STARTED("Sessions/Playing"),
    PROGRESS("Sessions/Playing/Progress"),
    STOPPED("Sessions/Playing/Stopped"),
}

/** Read-only catalog access and the associated account lifecycle. Tokens are scoped to one server. */
class JellyfinClient(
    endpoint: String,
    private val deviceId: String,
    private val version: String,
    allowHttpForFixture: Boolean = false,
    private val http: OkHttpClient = OkHttpClient.Builder()
        .followRedirects(false)
        .followSslRedirects(false)
        .connectTimeout(12, TimeUnit.SECONDS)
        .callTimeout(35, TimeUnit.SECONDS)
        .build(),
) {
    private val address = DavAddress(endpoint, allowHttpForFixture)
    private val json = Json { ignoreUnknownKeys = true }

    init {
        require(HEADER_VALUE.matches(deviceId) && HEADER_VALUE.matches(version)) {
            "Invalid MediaVault device identity."
        }
    }

    private fun request(url: HttpUrl, session: JellyfinSession? = null): Request.Builder {
        val token = session?.token
        if (token != null && !HEADER_VALUE.matches(token)) throw JellyfinException("The server returned an invalid session.")
        val client = """MediaBrowser Client="MediaVault", Device="Android TV", DeviceId="$deviceId", Version="$version""""
        return Request.Builder().url(url)
            .header("Authorization", if (token == null) client else """$client, Token="$token"""")
            .header("Accept", "application/json")
    }

    suspend fun signIn(username: String, password: String): JellyfinSession {
        require(username.isNotBlank()) { "Enter your Jellyfin username." }
        return authenticated(send(request(address.url("Users/AuthenticateByName")).postBody(buildJsonObject {
            put("Username", username)
            put("Pw", password)
        })))
    }

    suspend fun beginQuickConnect(): JellyfinQuickConnect =
        send(request(address.url("QuickConnect/Initiate")).postBody(buildJsonObject {}))

    suspend fun pollQuickConnect(secret: String): JellyfinQuickConnect =
        send(request(address.url("QuickConnect/Connect").newBuilder().addQueryParameter("secret", secret).build()))

    suspend fun finishQuickConnect(secret: String): JellyfinSession =
        authenticated(send(request(address.url("Users/AuthenticateWithQuickConnect")).postBody(buildJsonObject {
            put("Secret", secret)
        })))

    suspend fun signOut(session: JellyfinSession) {
        exchange(request(address.url("Sessions/Logout"), session).postBody(buildJsonObject {}).build(), false)
    }

    suspend fun libraries(session: JellyfinSession): List<JellyfinItem> {
        val url = address.url("UserViews").newBuilder()
            .addQueryParameter("userId", session.user.id)
            .addQueryParameter("includeExternalContent", "false")
            .addQueryParameter("includeHidden", "false").build()
        return send<JellyfinPage>(request(url, session)).items
    }

    /** Reports catalog pages only after their IDs and offsets have been validated. */
    suspend fun catalog(session: JellyfinSession, libraryId: String, onPage: suspend (List<JellyfinItem>) -> Unit) {
        val seen = mutableSetOf<String>()
        var start = 0
        while (true) {
            coroutineContext.ensureActive()
            val url = address.url("Items").newBuilder()
                .addQueryParameter("userId", session.user.id)
                .addQueryParameter("parentId", libraryId)
                .addQueryParameter("recursive", "true")
                .addQueryParameter("includeItemTypes", "Movie,Series,Season,Episode,Photo,MusicAlbum,Audio")
                .addQueryParameter("fields", "Overview")
                .addQueryParameter("enableUserData", "false")
                .addQueryParameter("sortBy", "SortName")
                .addQueryParameter("startIndex", start.toString())
                .addQueryParameter("limit", PAGE_SIZE.toString()).build()
            val page = send<JellyfinPage>(request(url, session))
            if (page.items.size > PAGE_SIZE || (page.start != null && page.start != start) ||
                page.total?.let { it < 0 } == true) throw JellyfinException("The server returned an invalid catalog page.")
            if (page.items.isEmpty()) {
                if (page.total?.let { start < it } == true) throw JellyfinException("The catalog changed during import. Try again.")
                return
            }
            for (item in page.items) {
                if (item.id.isEmpty() || !seen.add(item.id)) throw JellyfinException("The catalog changed during import. Try again.")
            }
            onPage(page.items)
            start += page.items.size
            val total = page.total
            if (total != null && start >= total || total == null && page.items.size < PAGE_SIZE) return
            if (start >= MAX_ITEMS) throw JellyfinException("This library is too large. Choose a smaller library.")
        }
    }

    /** The caller supplies device capabilities from its player before requesting a playable variant. */
    suspend fun playback(
        session: JellyfinSession,
        itemId: String,
        deviceProfile: JsonObject,
        startMillis: Long = 0,
    ): JellyfinPlayback {
        val url = urlFor("Items", itemId, "PlaybackInfo")
        val info = send<JellyfinPlaybackInfo>(request(url, session).postBody(buildJsonObject {
            put("UserId", session.user.id)
            put("DeviceProfile", deviceProfile)
            put("EnableDirectPlay", true)
            put("EnableDirectStream", true)
            put("EnableTranscoding", true)
            put("StartTimeTicks", millisToTicks(startMillis))
        }))
        val playSessionId = info.playSessionId?.takeIf(String::isNotBlank)
            ?: throw JellyfinException("The server did not start a playback session.")
        val direct = info.sources.firstOrNull { it.directPlay }
        val source = direct ?: info.sources.firstOrNull { !it.transcodingUrl.isNullOrEmpty() }
            ?: throw JellyfinException("Jellyfin could not find a format this device can play.")
        val streamUrl = if (direct != null) {
            urlFor("Videos", itemId, "stream").newBuilder()
                .addQueryParameter("static", "true")
                .addQueryParameter("mediaSourceId", source.id)
                .addQueryParameter("playSessionId", playSessionId)
                .addQueryParameter("deviceId", deviceId)
                .build()
        } else {
            scopedVideoUrl(source.transcodingUrl.orEmpty(), itemId)
        }
        val subtitles = source.streams.filter { it.type == "Subtitle" && it.index >= 0 && it.isTextSubtitle }
            .map { stream ->
                val subtitleUrl = urlFor("Videos", itemId, source.id, "Subtitles", stream.index.toString(), "Stream.vtt")
                JellyfinSubtitle(stream.index, stream.language, stream.isForced, subtitleUrl)
            }
        return JellyfinPlayback(itemId, source.id, playSessionId, if (direct != null) "DirectPlay" else "Transcode",
            streamUrl, subtitles)
    }

    suspend fun report(
        session: JellyfinSession,
        playback: JellyfinPlayback,
        event: JellyfinPlaybackEvent,
        positionMillis: Long,
        paused: Boolean = false,
        failed: Boolean = false,
    ) {
        val body = buildJsonObject {
            put("ItemId", playback.itemId)
            put("MediaSourceId", playback.mediaSourceId)
            put("PlaySessionId", playback.playSessionId)
            put("PositionTicks", millisToTicks(positionMillis))
            if (event == JellyfinPlaybackEvent.STOPPED) {
                put("Failed", failed)
            } else {
                put("PlayMethod", playback.method)
                put("IsPaused", paused)
                put("CanSeek", true)
            }
        }
        exchange(request(address.url(event.route), session).postBody(body).build(), false)
    }

    fun artwork(item: JellyfinItem, width: Int): HttpUrl? {
        val tag = item.imageTags["Primary"] ?: return null
        require(width in 1..4096)
        return urlFor("Items", item.id, "Images", "Primary").newBuilder()
            .addQueryParameter("tag", tag)
            .addQueryParameter("maxWidth", width.toString()).build()
    }

    /** Pass this on every asset and HLS segment request. Never forward it through a redirect. */
    fun assetRequest(session: JellyfinSession, url: HttpUrl): Request {
        if (url.queryParameterNames.any { it.equals("api_key", ignoreCase = true) } || !isScoped(url)) {
            throw JellyfinException("Jellyfin returned a media address outside this server.")
        }
        return request(url, session).removeHeader("Accept").build()
    }

    private fun millisToTicks(milliseconds: Long): Long {
        require(milliseconds in 0..Long.MAX_VALUE / 10_000)
        return milliseconds * 10_000
    }

    private fun urlFor(vararg parts: String): HttpUrl {
        if (!parts.all({ DavAddress.safeComponent(it) })) throw JellyfinException("Jellyfin returned an invalid media identifier.")
        return address.url(parts.joinToString("/"))
    }

    private fun isScoped(url: HttpUrl): Boolean {
        val base = address.base
        val prefix = base.pathSegments.dropLast(1)
        return url.scheme == base.scheme && url.host == base.host && url.port == base.port &&
            url.username.isEmpty() && url.password.isEmpty() && url.fragment == null &&
            url.pathSegments.size > prefix.size && url.pathSegments.take(prefix.size) == prefix &&
            url.pathSegments.all({ DavAddress.safeComponent(it) })
    }

    private fun scopedVideoUrl(raw: String, itemId: String): HttpUrl {
        val base = address.base
        val prefix = base.pathSegments.dropLast(1)
        val target = (if (raw.startsWith("/Videos/")) base.resolve(raw.removePrefix("/")) else base.resolve(raw))
            ?.takeIf { isScoped(it) && it.pathSegments.drop(prefix.size).take(2) == listOf("Videos", itemId) }
            ?: throw JellyfinException("Jellyfin returned a playback address outside this server.")
        return target.newBuilder().apply {
            target.queryParameterNames.filter { it.equals("api_key", ignoreCase = true) }
                .forEach { removeAllQueryParameters(it) }
        }.build()
    }

    private fun authenticated(session: JellyfinSession): JellyfinSession {
        if (session.user.id.isBlank() || !HEADER_VALUE.matches(session.token)) {
            throw JellyfinException("The Jellyfin server returned an invalid session.")
        }
        return session
    }

    private fun Request.Builder.postBody(body: JsonObject): Request.Builder =
        post(json.encodeToString(body).toRequestBody("application/json; charset=utf-8".toMediaType()))

    private suspend inline fun <reified T> send(request: Request.Builder): T {
        val content = exchange(request.build(), true)
        try {
            return json.decodeFromString(content)
        } catch (_: IllegalArgumentException) {
            throw JellyfinException("The server returned an invalid Jellyfin response.")
        }
    }

    private suspend fun exchange(request: Request, readBody: Boolean): String = runInterruptible(Dispatchers.IO) {
        http.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                val status = response.code
                throw JellyfinException(when (status) {
                    401 -> "Jellyfin rejected this sign-in or the session expired."
                    403 -> "This Jellyfin account cannot access the requested content."
                    404 -> "The Jellyfin server could not find that library or feature."
                    in 300..399 -> "Enter the final Jellyfin server address. Redirects are blocked to protect your sign-in."
                    else -> "The Jellyfin request failed (HTTP $status)."
                }, status)
            }
            if (!readBody) return@use ""
            val source = response.body?.source() ?: throw JellyfinException("The Jellyfin response was empty.")
            if (source.request(MAX_RESPONSE + 1)) throw JellyfinException("The Jellyfin response is too large.")
            source.readUtf8()
        }
    }

    private companion object {
        val HEADER_VALUE = Regex("[A-Za-z0-9_.-]{1,128}")
        const val PAGE_SIZE = 100
        const val MAX_RESPONSE = 8L * 1024 * 1024
        const val MAX_ITEMS = 250_000
    }
}
