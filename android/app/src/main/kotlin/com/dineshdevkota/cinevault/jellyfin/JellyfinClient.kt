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
