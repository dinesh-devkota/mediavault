package com.dineshdevkota.cinevault.cloud

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import okhttp3.FormBody
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.UUID

/** Public-client device login for a personal Microsoft account. Graph tokens stay on Graph. */
internal class OneDriveClient(
    clientId: String,
    http: OkHttpClient? = null,
    private val nowMillis: () -> Long = { System.nanoTime() / 1_000_000 },
) {
    val applicationId = UUID.fromString(clientId).toString().also {
        require(it.equals(clientId, ignoreCase = true)) { "Configure a Microsoft public client application ID." }
    }
    private val transport = http?.let(::CloudHttp) ?: CloudHttp()

    class Challenge internal constructor(
        val userCode: String,
        val verificationUri: HttpUrl,
        internal val deviceCode: String,
        internal val expiresIn: Int,
        internal val interval: Int,
        internal val received: Long,
        internal val clientId: String,
    )

    @Serializable
    class Credentials(
        @SerialName("access_token") val accessToken: String,
        @SerialName("refresh_token") val refreshToken: String? = null,
        @SerialName("expires_in") val expiresIn: Int,
    )

    @Serializable
    data class Entry(
        val id: String,
        val name: String,
        val size: Long? = null,
        val folder: Folder? = null,
        val file: File? = null,
        val remoteItem: JsonElement? = null,
    ) {
        @Serializable
        data class Folder(val childCount: Int? = null)
        @Serializable
        data class File(val mimeType: String? = null)
    }

    @Serializable
    private data class DeviceCode(
        @SerialName("user_code") val userCode: String,
        @SerialName("verification_uri") val verificationUri: String,
        @SerialName("device_code") val deviceCode: String,
        @SerialName("expires_in") val expiresIn: Int,
        val interval: Int = 5,
    )

    @Serializable
    private data class OAuthError(val error: String)

    @Serializable
    private data class Drive(val id: String)

    @Serializable
    private data class Page(val value: List<Entry>, @SerialName("@odata.nextLink") val next: String? = null)

    @Serializable
    private data class DownloadItem(
        val id: String,
        @SerialName("@microsoft.graph.downloadUrl") val downloadUrl: String? = null,
    )

    suspend fun beginSignIn(): Challenge {
        val result = decode<DeviceCode>(oauth("devicecode", "scope" to SCOPE))
        val verification = result.verificationUri.toHttpUrlOrNull()?.takeIf {
            it.isSafeTls() && it.host in VERIFICATION_HOSTS
        } ?: throw CloudClientException("Microsoft returned an invalid verification address.")
        if (result.expiresIn !in 1..3600 || result.interval !in 1..3600 ||
            result.deviceCode.isBlank() || result.userCode.isBlank()
        ) {
            throw CloudClientException("Microsoft returned an invalid sign-in challenge.")
        }
        return Challenge(result.userCode, verification, result.deviceCode, result.expiresIn, result.interval,
            nowMillis(), applicationId)
    }

    suspend fun completeSignIn(challenge: Challenge): Credentials {
        require(challenge.clientId == applicationId) { "This sign-in code is for a different Microsoft application." }
        val duration = challenge.expiresIn * 1000L
        var interval = challenge.interval * 1000L
        while (true) {
            val remaining = duration - (nowMillis() - challenge.received)
            if (remaining <= 0) throw CloudClientException("The Microsoft sign-in code expired.")
            delay(minOf(interval, remaining))
            if (nowMillis() - challenge.received >= duration) {
                throw CloudClientException("The Microsoft sign-in code expired.")
            }
            val response = oauth(
                "token", "grant_type" to "urn:ietf:params:oauth:grant-type:device_code",
                "device_code" to challenge.deviceCode, additionalStatus = 400,
            )
            if (response.status == 200) return credentials(response)
            when (decode<OAuthError>(response).error) {
                "authorization_pending" -> continue
                "slow_down" -> interval += 5_000
                "authorization_declined" -> throw CloudClientException("Microsoft sign-in was declined.")
                "expired_token" -> throw CloudClientException("The Microsoft sign-in code expired.")
                else -> throw CloudClientException("Microsoft rejected the sign-in request.", response.status)
            }
        }
    }

    suspend fun refresh(refreshToken: String): Credentials {
        require(refreshToken.isNotBlank()) { "Sign in to Microsoft again." }
        return credentials(oauth(
            "token", "grant_type" to "refresh_token", "refresh_token" to refreshToken, "scope" to SCOPE,
        ))
    }

    suspend fun driveIdentity(accessToken: String): String {
        val url = GRAPH.newBuilder().addQueryParameter("\$select", "id").build()
        val response = transport.exchange(Request.Builder().url(url).bearer(accessToken).build())
        val identity = decode<Drive>(response).id
        if (!ITEM_ID.matches(identity)) throw CloudClientException("Microsoft returned an invalid drive identity.")
        return identity
    }

    suspend fun listChildren(
        folder: String? = null,
        accessToken: String,
        onPage: suspend (List<Entry>) -> Unit,
    ) {
        require(folder == null || ITEM_ID.matches(folder)) { "Invalid OneDrive folder ID." }
        val requested = GRAPH.newBuilder().apply {
            if (folder == null) addPathSegment("root") else addPathSegment("items").addPathSegment(folder)
            addPathSegment("children")
        }.build()
        var next = requested
        val seen = mutableSetOf<HttpUrl>()
        while (true) {
            currentCoroutineContext().ensureActive()
            if (seen.size >= 10_000 || !seen.add(next) || !isChildPage(next, requested, folder)) {
                throw CloudClientException("Microsoft returned an invalid folder continuation.")
            }
            val request = Request.Builder().url(next).bearer(accessToken).build()
            val page = decode<Page>(transport.exchange(request))
            val continuation = page.next?.let {
                it.toHttpUrlOrNull() ?: throw CloudClientException("Microsoft returned an invalid folder continuation.")
            }
            onPage(page.value)
            next = continuation ?: return
        }
    }

    suspend fun read(id: String, offset: Long, length: Int, accessToken: String): ByteArray {
        require(ITEM_ID.matches(id)) { "Invalid OneDrive file ID." }
        val end = rangeEnd(offset, length)
        val url = GRAPH.newBuilder().addPathSegment("items").addPathSegment(id)
            .addQueryParameter("\$select", "id,@microsoft.graph.downloadUrl").build()
        val item = decode<DownloadItem>(transport.exchange(Request.Builder().url(url).bearer(accessToken).build()))
        val signed = item.downloadUrl?.toHttpUrlOrNull()?.takeIf { it.isSafeTls() && item.id == id }
            ?: throw CloudClientException("Microsoft returned an invalid media download address.")
        val request = Request.Builder().url(signed).header("Range", "bytes=$offset-$end")
            .header("Accept-Encoding", "identity").build()
        return transport.exchange(request, status = 206, limit = length).verifiedRange(offset, end, length)
    }

    private suspend fun oauth(path: String, vararg fields: Pair<String, String>, additionalStatus: Int? = null): CloudResponse {
        val form = FormBody.Builder().add("client_id", applicationId).apply {
            fields.forEach { (name, value) -> add(name, value) }
        }.build()
        val endpoint = OAUTH.newBuilder().addPathSegment(path).build()
        return transport.exchange(Request.Builder().url(endpoint).post(form).build(),
            limit = 64 * 1024, additionalStatus = additionalStatus)
    }

    private fun credentials(response: CloudResponse): Credentials {
        val result = decode<Credentials>(response)
        if (result.expiresIn <= 0 || result.accessToken.isEmpty() || result.accessToken.any { it !in '!'..'~' }) {
            throw CloudClientException("Microsoft returned invalid credentials.")
        }
        return result
    }

    private inline fun <reified T> decode(response: CloudResponse): T = try {
        json.decodeFromString(response.data.decodeToString())
    } catch (_: SerializationException) {
        throw CloudClientException("Microsoft returned an invalid OneDrive response.")
    }

    private fun isChildPage(url: HttpUrl, requested: HttpUrl, folder: String?): Boolean {
        if (!url.isSafeTls() || url.host != GRAPH.host) return false
        if (url.pathSegments == requested.pathSegments) return true
        val parts = url.pathSegments
        return parts.size == 6 && parts[0] == "v1.0" && parts[1] == "drives" && ITEM_ID.matches(parts[2]) &&
            parts[3] == "items" && ITEM_ID.matches(parts[4]) &&
            (folder == null || parts[4] == folder) && parts[5] == "children"
    }

    private fun HttpUrl.isSafeTls(): Boolean = isHttps && port == 443 && username.isEmpty() &&
        password.isEmpty() && fragment == null

    private companion object {
        val GRAPH = "https://graph.microsoft.com/v1.0/me/drive".toHttpUrl()
        val OAUTH = "https://login.microsoftonline.com/consumers/oauth2/v2.0".toHttpUrl()
        val ITEM_ID = Regex("[A-Za-z0-9!_-]{1,256}")
        val VERIFICATION_HOSTS = setOf("microsoft.com", "www.microsoft.com", "login.microsoftonline.com")
        const val SCOPE = "https://graph.microsoft.com/Files.Read offline_access"
        val json = Json { ignoreUnknownKeys = true }
    }
}
