package com.dineshdevkota.cinevault.cloud

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request

/** Requests use a caller-supplied token and are limited to the Drive v3 API. */
internal class GoogleDriveClient(http: OkHttpClient? = null) {
    private val transport = http?.let(::CloudHttp) ?: CloudHttp()

    @Serializable
    data class Entry(
        val id: String,
        val name: String,
        val mimeType: String,
        val size: String? = null,
        val resourceKey: String? = null,
    ) {
        val isFolder: Boolean get() = mimeType == "application/vnd.google-apps.folder"
    }

    @Serializable
    private data class Page(val files: List<Entry>, val nextPageToken: String? = null)

    suspend fun listChildren(
        folder: String,
        accessToken: String,
        resourceKey: String? = null,
        onPage: suspend (List<Entry>) -> Unit,
    ) {
        require(FILE_ID.matches(folder)) { "Invalid Drive folder ID." }
        var cursor: String? = null
        val seen = mutableSetOf<String>()
        do {
            currentCoroutineContext().ensureActive()
            val url = BASE.newBuilder()
                .addQueryParameter("q", "'$folder' in parents and trashed = false")
                .addQueryParameter("fields", "nextPageToken,files(id,name,mimeType,size,resourceKey)")
                .addQueryParameter("supportsAllDrives", "true")
                .addQueryParameter("includeItemsFromAllDrives", "true")
                .addQueryParameter("pageSize", "100")
                .apply { cursor?.let { addQueryParameter("pageToken", it) } }
                .build()
            val request = Request.Builder().url(url).bearer(accessToken).addResourceKey(folder, resourceKey).build()
            val page = try {
                JSON.decodeFromString<Page>(transport.exchange(request).data.decodeToString())
            } catch (_: SerializationException) {
                throw CloudClientException("Drive returned an invalid catalog page.")
            }
            val nextPage = page.nextPageToken
            if (nextPage != null && (nextPage.isBlank() || seen.size >= 10_000 || !seen.add(nextPage))) {
                throw CloudClientException("Drive returned an invalid catalog cursor.")
            }
            onPage(page.files)
            cursor = nextPage
        } while (cursor != null)
    }

    suspend fun read(
        file: String,
        offset: Long,
        length: Int,
        accessToken: String,
        resourceKey: String? = null,
    ): ByteArray {
        require(FILE_ID.matches(file)) { "Invalid Drive file ID." }
        val end = rangeEnd(offset, length)
        val url = BASE.newBuilder().addPathSegment(file)
            .addQueryParameter("alt", "media")
            .addQueryParameter("supportsAllDrives", "true").build()
        val request = Request.Builder().url(url).bearer(accessToken).addResourceKey(file, resourceKey)
            .header("Range", "bytes=$offset-$end").header("Accept-Encoding", "identity").build()
        return transport.exchange(request, status = 206, limit = length).verifiedRange(offset, end, length)
    }

    private fun Request.Builder.addResourceKey(id: String, key: String?): Request.Builder {
        if (key != null) {
            require(FILE_ID.matches(key)) { "Invalid Drive resource key." }
            header("X-Goog-Drive-Resource-Keys", "$id/$key")
        }
        return this
    }

    private companion object {
        val BASE = "https://www.googleapis.com/drive/v3/files".toHttpUrl()
        val FILE_ID = Regex("[A-Za-z0-9_-]{1,256}")
        val JSON = Json { ignoreUnknownKeys = true }
    }
}
