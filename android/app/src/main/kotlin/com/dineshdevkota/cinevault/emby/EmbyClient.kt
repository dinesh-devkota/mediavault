package com.dineshdevkota.cinevault.emby

import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runInterruptible
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

class EmbyException(message: String, val status: Int? = null) : IOException(message)

class EmbyClient(endpoint: String, deviceId: String, version: String) {
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

    private val base = requireNotNull(endpoint.trim().toHttpUrlOrNull()?.takeIf {
        it.isHttps && it.username.isEmpty() && it.password.isEmpty() && it.query == null && it.fragment == null
    }) { "Enter the complete HTTPS address for your Emby server." }
    private val authorization: String

    init {
        require(headerValue(deviceId) && headerValue(version))
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

    private suspend fun send(path: List<String>, account: Account? = null, query: Map<String, String> = emptyMap(),
                             body: String? = null): String = runInterruptible(Dispatchers.IO) {
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
        http.newCall(request.build()).execute().use { response ->
            if (!response.isSuccessful) throw EmbyException("Emby returned HTTP ${response.code}.", response.code)
            val source = response.body?.source() ?: return@use ""
            if (source.request(8L * 1024 * 1024 + 1)) throw EmbyException("The Emby response is too large.")
            source.readUtf8()
        }
    }

    private fun invalidCatalog(): Nothing = throw EmbyException("The Emby catalog changed during the scan. Try again.")

    private companion object {
        val json = Json { ignoreUnknownKeys = true }
        val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false)
            .callTimeout(30, TimeUnit.SECONDS).build()
        val safeValue = Regex("[A-Za-z0-9_.-]{1,256}")
        fun headerValue(value: String): Boolean = value != "." && value != ".." && safeValue.matches(value)
    }
}
