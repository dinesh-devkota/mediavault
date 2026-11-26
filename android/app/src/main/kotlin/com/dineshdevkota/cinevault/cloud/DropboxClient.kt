package com.dineshdevkota.cinevault.cloud

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.FormBody
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.util.concurrent.TimeUnit

/** Dropbox's manual PKCE flow lets the source owner complete approval on another device. */
internal class DropboxClient(private val appKey: String, http: OkHttpClient? = null) {
    private val transport = http?.let(::CloudHttp) ?: CloudHttp()

    init {
        require(APP_KEY.matches(appKey)) { "Enter a valid registered Dropbox app key." }
    }

    class Approval internal constructor(
        val url: HttpUrl,
        internal val appKey: String,
        internal val verifier: String,
        internal val started: Long,
    )

    @Serializable
    class Credentials(
        @SerialName("access_token") val accessToken: String,
        @SerialName("refresh_token") val refreshToken: String? = null,
        @SerialName("expires_in") val expiresIn: Int,
        @SerialName("account_id") val accountId: String? = null,
    )

    @Serializable
    data class Entry(
        @SerialName(".tag") val kind: String = "file",
        val name: String,
        val id: String? = null,
        @SerialName("path_display") val displayPath: String? = null,
        val size: Long? = null,
        @SerialName("rev") val revision: String? = null,
        @SerialName("is_downloadable") val downloadable: Boolean = true,
    )

    @Serializable
    private data class Page(val entries: List<Entry>, val cursor: String, @SerialName("has_more") val hasMore: Boolean)

    fun beginAuthorization(): Approval {
        val bytes = ByteArray(32).also(random::nextBytes)
        val verifier = base64.encodeToString(bytes)
        val challenge = base64.encodeToString(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray(Charsets.US_ASCII)))
        val url = "https://www.dropbox.com/oauth2/authorize".toHttpUrl().newBuilder()
            .addQueryParameter("response_type", "code")
            .addQueryParameter("client_id", appKey)
            .addQueryParameter("token_access_type", "offline")
            .addQueryParameter("scope", "files.metadata.read files.content.read")
            .addQueryParameter("code_challenge_method", "S256")
            .addQueryParameter("code_challenge", challenge)
            .build()
        return Approval(url, appKey, verifier, System.nanoTime())
    }

    suspend fun completeAuthorization(approval: Approval, inputCode: String): Credentials {
        val code = inputCode.trim()
        require(approval.appKey == appKey && System.nanoTime() - approval.started < TimeUnit.MINUTES.toNanos(10) &&
            code.length in 1..2048 && code.all { it in '!'..'~' }) { "Invalid or expired Dropbox approval." }
        return token(
            "grant_type" to "authorization_code",
            "code" to code,
            "code_verifier" to approval.verifier,
        )
    }

    suspend fun refresh(refreshToken: String): Credentials =
        token("grant_type" to "refresh_token", "refresh_token" to refreshToken)

    suspend fun revoke(accessToken: String) {
        api("auth/token/revoke", accessToken)
    }

    suspend fun metadata(path: String, accessToken: String): Entry =
        decode(api("files/get_metadata", accessToken, mapOf("path" to path)))

    suspend fun listFolder(
        path: String, accessToken: String,
        authorize: () -> Unit = {}, onPage: suspend (List<Entry>) -> Unit,
    ) {
        authorize()
        var page = decode<Page>(api("files/list_folder", accessToken, mapOf("path" to path)))
        val seen = mutableSetOf<String>()
        while (true) {
            currentCoroutineContext().ensureActive()
            authorize()
            if (page.hasMore && (page.cursor.isBlank() || seen.size >= 10_000 || !seen.add(page.cursor))) {
                throw CloudClientException("Dropbox returned an invalid catalog cursor.")
            }
            onPage(page.entries)
            if (!page.hasMore) return
            page = decode(api("files/list_folder/continue", accessToken, mapOf("cursor" to page.cursor)))
        }
    }

    suspend fun read(id: String, offset: Long, length: Int, accessToken: String): ByteArray {
        require(validId(id)) { "Invalid Dropbox file ID." }
        return download(id, offset, length, accessToken).verifiedRange(offset, rangeEnd(offset, length), length)
    }

    /** Reject ranges from a moved file or a different revision at the same path. */
    suspend fun read(file: Entry, offset: Long, length: Int, accessToken: String): ByteArray {
        val revision = file.revision?.takeIf(REVISION::matches)
            ?: throw CloudClientException("Dropbox did not return a valid file revision.")
        val path = file.displayPath ?: throw CloudClientException("Dropbox did not return a valid file path.")
        val response = download(path, offset, length, accessToken)
        val result = response.headers["Dropbox-API-Result"]?.let { decode<Entry>(it.encodeToByteArray()) }
        if (result == null || result.id != file.id || result.revision != revision || result.size != file.size ||
            !result.displayPath.equals(path, ignoreCase = true)) {
            throw CloudClientException("The Dropbox file changed. Reopen it and try again.")
        }
        return response.verifiedRange(offset, rangeEnd(offset, length), length, expectedTotal = file.size)
    }

    private suspend fun download(reference: String, offset: Long, length: Int, accessToken: String): CloudResponse {
        val end = rangeEnd(offset, length)
        val request = Request.Builder().url("https://content.dropboxapi.com/2/files/download").bearer(accessToken)
            .header("Dropbox-API-Arg", headerArgument(reference))
            .header("Range", "bytes=$offset-$end").header("Accept-Encoding", "identity")
            .post(emptyBody).build()
        return transport.exchange(request, status = 206, limit = length)
    }

    private suspend fun token(vararg fields: Pair<String, String>): Credentials {
        val form = FormBody.Builder().add("client_id", appKey).apply {
            for ((name, value) in fields) add(name, value)
        }.build()
        val request = Request.Builder().url("https://api.dropboxapi.com/oauth2/token").post(form).build()
        return decode(transport.exchange(request).data)
    }

    private suspend fun api(path: String, accessToken: String, arguments: Map<String, String>? = null): ByteArray {
        val body = arguments?.let { json.encodeToString(it).toRequestBody(jsonType) } ?: emptyBody
        val request = Request.Builder().url("https://api.dropboxapi.com/2/$path").bearer(accessToken)
            .post(body).build()
        return transport.exchange(request).data
    }

    private fun headerArgument(path: String): String = buildString {
        for (char in json.encodeToString(mapOf("path" to path))) {
            if (char.code < 127) append(char)
            else append("\\u").append(char.code.toString(16).padStart(4, '0'))
        }
    }

    private inline fun <reified T> decode(bytes: ByteArray): T = try {
        json.decodeFromString(bytes.decodeToString())
    } catch (_: SerializationException) {
        throw CloudClientException("Dropbox returned an invalid response.")
    }

    companion object {
        private val random = SecureRandom()
        private val base64 = Base64.getUrlEncoder().withoutPadding()
        private val APP_KEY = Regex("[A-Za-z0-9_-]{1,128}")
        private val FILE_ID = Regex("id:[A-Za-z0-9_-]{1,253}")
        private val REVISION = Regex("[A-Fa-f0-9]{9,128}")
        private val json = Json { ignoreUnknownKeys = true }
        private val jsonType = "application/json; charset=utf-8".toMediaType()
        private val emptyBody = byteArrayOf().toRequestBody()

        fun validId(id: String?): Boolean = id != null && FILE_ID.matches(id)
    }
}
