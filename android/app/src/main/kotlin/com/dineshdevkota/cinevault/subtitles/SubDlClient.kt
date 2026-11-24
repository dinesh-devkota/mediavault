package com.dineshdevkota.cinevault.subtitles

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.URI
import java.util.Locale
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resumeWithException

enum class SubDlMediaType(val value: String) { MOVIE("movie"), TV("tv") }

data class SubDlSearchQuery(
    val tmdbId: Int,
    val type: SubDlMediaType,
    val season: Int? = null,
    val episode: Int? = null,
    val language: String = "en",
)

data class SubDlSubtitle(
    val id: String,
    val language: String,
    val releaseName: String,
    val format: String,
    val hearingImpaired: Boolean,
    val downloadUrl: String,
    val fps: Double?,
    val releaseNames: List<String> = emptyList(),
)

enum class SubDlFailure {
    MISSING_KEY, INVALID_KEY, QUOTA, CONNECTION, NO_RESULTS, INVALID_RESPONSE, TOO_LARGE, INVALID_QUERY, UNSAFE_DOWNLOAD,
}

/** Deliberately never includes server response text, request URLs, keys, or an underlying network exception. */
class SubDlException(val failure: SubDlFailure) : Exception(when (failure) {
    SubDlFailure.MISSING_KEY -> "Connect SubDL in Settings to find subtitles."
    SubDlFailure.INVALID_KEY -> "SubDL could not verify this API key. Check it in Settings."
    SubDlFailure.QUOTA -> "SubDL's request limit has been reached. Try again after the limit resets."
    SubDlFailure.CONNECTION -> "Could not reach SubDL. Check your internet connection and try again."
    SubDlFailure.NO_RESULTS -> "No matching SRT or VTT subtitles were found for this title and language."
    SubDlFailure.INVALID_RESPONSE -> "SubDL returned an unsupported response. Try again later or use a subtitle from your NAS."
    SubDlFailure.TOO_LARGE -> "This subtitle exceeds the 2 MB limit. Choose another subtitle."
    SubDlFailure.INVALID_QUERY -> "Match this title and episode in the library before finding subtitles."
    SubDlFailure.UNSAFE_DOWNLOAD -> "This subtitle download is not supported. Choose another subtitle."
})

data class SubDlHttpResponse(val statusCode: Int, val url: String, val data: ByteArray)

fun interface SubDlTransport {
    suspend fun execute(request: Request, maximumBytes: Int): SubDlHttpResponse
}

/** v2 search is authenticated; raw per-file downloads are anonymous. Neither keys nor results are retained here. */
class SubDlClient(private val transport: SubDlTransport = NativeSubDlTransport()) {
    suspend fun validateKey(apiKey: String) {
        val body = json(apiRequest("/api/v2/me", apiKey))
        val plan = body["plan"] as? JsonObject
        val usage = body["usage"] as? JsonObject
        if (plan?.text("name").isNullOrBlank() || usage?.get("search") !is JsonObject) {
            fail(SubDlFailure.INVALID_RESPONSE)
        }
    }

    suspend fun search(query: SubDlSearchQuery, apiKey: String): List<SubDlSubtitle> {
        val language = normalizedLanguage(query.language) ?: fail(SubDlFailure.INVALID_QUERY)
        if (query.tmdbId <= 0) fail(SubDlFailure.INVALID_QUERY)
        val parameters = linkedMapOf(
            "tmdb_id" to query.tmdbId.toString(), "type" to query.type.value, "languages" to language,
            "unpack" to "1", "full_season" to "0", "releases" to "1", "client" to "custom_integration", "subs_per_page" to "30",
        )
        if (query.type == SubDlMediaType.TV) {
            if (query.season == null || query.season !in 0..999 || query.episode == null || query.episode !in 0..999) fail(SubDlFailure.INVALID_QUERY)
            parameters["season"] = query.season.toString()
            parameters["episode"] = query.episode.toString()
        } else if (query.season != null || query.episode != null) fail(SubDlFailure.INVALID_QUERY)
        val body = json(apiRequest("/api/v2/subtitles/search", apiKey, parameters))
        // SubDL associates subtitles only with results[0]. Matching a later title would be unsafe.
        val first = (body["results"] as? JsonArray)?.firstOrNull() as? JsonObject
        if (first?.integer("tmdb_id") != query.tmdbId || first?.text("type") != query.type.value) fail(SubDlFailure.NO_RESULTS)
        val rows = body["subtitles"] as? JsonArray ?: fail(SubDlFailure.NO_RESULTS)
        val found = mutableListOf<SubDlSubtitle>()
        val seen = mutableSetOf<String>()
        for (element in rows.take(30)) {
            val row = element as? JsonObject ?: continue
            val files = row["unpack_files"] as? JsonArray ?: continue
            for (entry in files) {
                val file = entry as? JsonObject ?: continue
                val format = file.text("format")?.lowercase(Locale.ROOT)?.takeIf { it == "srt" || it == "vtt" } ?: continue
                val fileLanguage = file.text("language")?.let(::normalizedLanguage)?.takeIf { it == language } ?: continue
                val url = file.text("url")?.let(::safeDownloadUrl) ?: continue
                if (file.text("file_n_id") != url.substringAfterLast('/')) continue
                val size = file.integer("size")
                if (size != null && size !in 1..MAXIMUM_BYTES) continue
                if (query.type == SubDlMediaType.TV) {
                    // Only a file's explicit episode identity is accepted, never an archive-level guess.
                    if (file.integer("season") != query.season || file.integer("episode") != query.episode) continue
                } else if ((file.integer("season") ?: 0) != 0 || (file.integer("episode") ?: 0) != 0) continue
                if (!seen.add(url)) continue
                val release = file.text("release_name")?.takeIf { it.isNotEmpty() }
                    ?: row.text("release_name") ?: file.text("name") ?: "Subtitle"
                val fps = ((file["fps"] ?: row["fps"]) as? JsonPrimitive)?.doubleOrNull
                    ?.takeIf { it.isFinite() && it > 0 && it <= 240 }
                val releases = (listOf(release) + file.strings("releases") + row.strings("releases"))
                    .filter { it.isNotEmpty() }.take(100).map { it.take(512) }.distinct()
                found += SubDlSubtitle(url, fileLanguage, release.take(512), format,
                    file.boolean("hi") ?: row.boolean("hi") ?: false, url, fps, releases)
                if (found.size == 30) return found
            }
        }
        if (found.isEmpty()) fail(SubDlFailure.NO_RESULTS)
        return found
    }

    suspend fun download(subtitle: SubDlSubtitle): ByteArray {
        if (subtitle.format != "srt" && subtitle.format != "vtt") fail(SubDlFailure.UNSAFE_DOWNLOAD)
        val url = safeDownloadUrl(subtitle.downloadUrl) ?: fail(SubDlFailure.UNSAFE_DOWNLOAD)
        val request = Request.Builder().url(url).header("Accept", "text/plain, text/vtt, application/octet-stream").build()
        val bytes = fetch(request).data
        if (bytes.isEmpty() || bytes.startsWith(byteArrayOf(0x50, 0x4b)) ||
            bytes.startsWith(byteArrayOf(0x52, 0x61, 0x72, 0x21))) fail(SubDlFailure.INVALID_RESPONSE)
        return bytes
    }

    private suspend fun json(request: Request): JsonObject {
        val data = fetch(request).data
        val body = try { Json.parseToJsonElement(data.decodeToString(throwOnInvalidSequence = true)) as? JsonObject }
            catch (_: IllegalArgumentException) { null }
            ?: fail(SubDlFailure.INVALID_RESPONSE)
        val error = body["error"]
        if (error is JsonObject) {
            when (error.text("code")) {
                "quota_exceeded", "rate_limit_exceeded", "rate_limited" -> fail(SubDlFailure.QUOTA)
                "invalid_api_key", "invalid_key", "unauthorized", "missing_api_key" -> fail(SubDlFailure.INVALID_KEY)
                else -> fail(SubDlFailure.INVALID_RESPONSE)
            }
        }
        if (body.boolean("status") == false || (error != null && error != kotlinx.serialization.json.JsonNull)) {
            fail(SubDlFailure.INVALID_RESPONSE)
        }
        return body
    }

    private suspend fun fetch(request: Request): SubDlHttpResponse {
        try {
            currentCoroutineContext().ensureActive()
            val reply = transport.execute(request, MAXIMUM_BYTES)
            currentCoroutineContext().ensureActive()
            if (reply.url != request.url.toString()) fail(SubDlFailure.UNSAFE_DOWNLOAD)
            if (reply.data.size > MAXIMUM_BYTES) fail(SubDlFailure.TOO_LARGE)
            when (reply.statusCode) {
                in 200..299 -> return reply
                401, 403 -> fail(if (request.header("Authorization") == null) SubDlFailure.CONNECTION else SubDlFailure.INVALID_KEY)
                429 -> fail(SubDlFailure.QUOTA)
                in 300..399 -> fail(SubDlFailure.UNSAFE_DOWNLOAD)
                else -> fail(SubDlFailure.CONNECTION)
            }
        } catch (error: CancellationException) { throw error }
        catch (error: SubDlException) { throw error }
        catch (_: Exception) { fail(SubDlFailure.CONNECTION) }
    }

    companion object {
        const val MAXIMUM_BYTES = 2 * 1_024 * 1_024

        private fun apiRequest(path: String, apiKey: String, parameters: Map<String, String> = emptyMap()): Request {
            val key = apiKey.trim()
            if (key.isEmpty()) fail(SubDlFailure.MISSING_KEY)
            if (key.length > 4_096 || key.any { it.code !in 33..126 }) fail(SubDlFailure.INVALID_KEY)
            val url = okhttp3.HttpUrl.Builder().scheme("https").host("api.subdl.com").encodedPath(path)
            parameters.toSortedMap().forEach { (name, value) -> url.addQueryParameter(name, value) }
            return Request.Builder().url(url.build()).header("Authorization", "Bearer $key").header("Accept", "application/json").build()
        }

        private fun normalizedLanguage(value: String): String? = value.trim().lowercase(Locale.ROOT).replace('_', '-')
            .takeIf { it.matches(Regex("[a-z]{2,3}(-[a-z]{2,4})?")) }

        internal fun safeDownloadUrl(value: String): String? {
            val absolute = if (value.startsWith("/subtitle/")) "https://dl.subdl.com$value" else value
            val uri = try { URI(absolute) } catch (_: Exception) { return null }
            if (uri.scheme != "https" || uri.host != "dl.subdl.com" || uri.rawUserInfo != null || uri.port != -1 ||
                uri.rawQuery != null || uri.rawFragment != null ||
                !uri.rawPath.matches(Regex("/subtitle/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+"))) return null
            return uri.toASCIIString()
        }

        private fun JsonObject.text(name: String): String? = (this[name] as? JsonPrimitive)?.takeIf { it.isString }?.content
        private fun JsonObject.integer(name: String): Int? = (this[name] as? JsonPrimitive)?.intOrNull
        private fun JsonObject.boolean(name: String): Boolean? = (this[name] as? JsonPrimitive)?.booleanOrNull
        private fun JsonObject.strings(name: String): List<String> = (this[name] as? JsonArray).orEmpty()
            .mapNotNull { (it as? JsonPrimitive)?.takeIf { value -> value.isString }?.content }
        private fun ByteArray.startsWith(prefix: ByteArray) = size >= prefix.size && prefix.indices.all { this[it] == prefix[it] }
        private fun fail(failure: SubDlFailure): Nothing = throw SubDlException(failure)
    }
}

/** A dedicated cookie-free client avoids sharing NAS credentials or application logging interceptors. */
private class NativeSubDlTransport : SubDlTransport {
    private val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false)
        .connectTimeout(10, TimeUnit.SECONDS).readTimeout(20, TimeUnit.SECONDS).callTimeout(30, TimeUnit.SECONDS)
        .build()

    override suspend fun execute(request: Request, maximumBytes: Int): SubDlHttpResponse = suspendCancellableCoroutine { continuation ->
        val call = http.newCall(request)
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                continuation.resumeWithException(SubDlException(SubDlFailure.CONNECTION))
            }

            override fun onResponse(call: Call, response: Response) {
                continuation.resumeWith(runCatching {
                    response.use { reply ->
                        if (reply.code !in 200..299) return@use SubDlHttpResponse(reply.code, reply.request.url.toString(), byteArrayOf())
                        val body = reply.body ?: throw SubDlException(SubDlFailure.INVALID_RESPONSE)
                        if (body.contentLength() > maximumBytes) throw SubDlException(SubDlFailure.TOO_LARGE)
                        val bytes = ByteArrayOutputStream()
                        body.byteStream().use { input ->
                            val buffer = ByteArray(8_192)
                            while (true) {
                                val count = input.read(buffer)
                                if (count == -1) break
                                if (count > maximumBytes - bytes.size()) throw SubDlException(SubDlFailure.TOO_LARGE)
                                bytes.write(buffer, 0, count)
                            }
                        }
                        SubDlHttpResponse(reply.code, reply.request.url.toString(), bytes.toByteArray())
                    }
                })
            }
        })
    }
}
