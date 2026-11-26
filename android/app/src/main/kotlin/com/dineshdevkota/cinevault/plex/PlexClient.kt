package com.dineshdevkota.cinevault.plex

import java.io.IOException
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.runInterruptible
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlin.coroutines.coroutineContext
import okhttp3.Headers
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

internal class PlexException(message: String, val status: Int? = null) : IOException(message)
internal data class PlexResponse(val status: Int, val data: ByteArray, val headers: Headers)
internal fun interface PlexExchange {
    suspend fun send(request: Request, maximumBytes: Int): PlexResponse
}

private const val MAXIMUM_CATALOG_BYTES = 8 * 1024 * 1024
private const val MAXIMUM_RANGE_BYTES = 8 * 1024 * 1024
private val json = Json { ignoreUnknownKeys = true }

internal object PlexHTTP : PlexExchange {
    private val client = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false)
        .callTimeout(30, TimeUnit.SECONDS).build()

    override suspend fun send(request: Request, maximumBytes: Int): PlexResponse = runInterruptible(Dispatchers.IO) {
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) return@use PlexResponse(response.code, byteArrayOf(), response.headers)
            val body = response.body ?: return@use PlexResponse(response.code, byteArrayOf(), response.headers)
            val source = body.source()
            if (body.contentLength() > maximumBytes || source.request(maximumBytes + 1L)) invalidResponse()
            PlexResponse(response.code, source.readByteArray(), response.headers)
        }
    }
}

internal class PlexAccountClient(private val deviceID: UUID, private val exchange: PlexExchange = PlexHTTP) {
    @Serializable
    data class Pin(val id: Long, val code: String, val expiresIn: Int)

    @Serializable
    private data class PinStatus(val authToken: String? = null)

    @Serializable
    class Server(
        val name: String,
        val clientIdentifier: String,
        val provides: String,
        internal val accessToken: String? = null,
        val connections: List<Connection> = emptyList(),
    ) {
        val secureConnections: List<Connection> get() = connections.filter { it.secureURL() != null }
    }

    @Serializable
    data class Connection(val uri: String, val local: Boolean, val relay: Boolean) {
        internal fun secureURL(): HttpUrl? = uri.toHttpUrlOrNull()?.takeIf {
            it.isHttps && it.username.isEmpty() && it.password.isEmpty() && it.query == null && it.fragment == null
        }
    }

    suspend fun beginLink(): Pin {
        val url = endpoint.newBuilder().addPathSegment("pins").addQueryParameter("strong", "false").build()
        val request = plexRequest(url, deviceID).post(byteArrayOf().toRequestBody()).build()
        val pin = json.decodeFromString<Pin>(exchange.body(request, acceptedStatus = setOf(200, 201)))
        if (pin.id <= 0 || pin.code.length !in 1..32 || pin.expiresIn <= 0) invalidResponse()
        return pin
    }

    suspend fun pollLink(pin: Pin): String? {
        if (pin.id <= 0 || pin.code.length !in 1..32) invalidResponse()
        val url = endpoint.newBuilder().addPathSegment("pins").addPathSegment(pin.id.toString())
            .addQueryParameter("code", pin.code).build()
        val status = json.decodeFromString<PinStatus>(exchange.body(plexRequest(url, deviceID).build()))
        val token = status.authToken?.takeUnless(String::isEmpty) ?: return null
        if (!validToken(token)) invalidResponse()
        return token
    }

    suspend fun servers(accountToken: String): List<Server> {
        if (!validToken(accountToken)) invalidResponse()
        val url = endpoint.newBuilder().addPathSegment("resources").addQueryParameter("includeHttps", "1")
            .addQueryParameter("includeRelay", "1").build()
        val request = plexRequest(url, deviceID).header("X-Plex-Token", accountToken).build()
        return json.decodeFromString<List<Server>>(exchange.body(request)).filter { server ->
            server.provides.split(',').contains("server") && server.clientIdentifier.isNotEmpty() &&
                server.secureConnections.isNotEmpty() && server.accessToken?.let(::validToken) == true
        }
    }

    private companion object {
        val endpoint = "https://plex.tv/api/v2".toHttpUrl()
    }
}

internal class PlexMediaClient(
    server: PlexAccountClient.Server,
    connection: PlexAccountClient.Connection,
    private val deviceID: UUID,
    private val exchange: PlexExchange = PlexHTTP,
) {
    @Serializable
    data class Library(val key: String, val title: String, val type: String)

    @Serializable
    data class Item(
        val ratingKey: String,
        val type: String,
        val title: String,
        val summary: String? = null,
        val year: Int? = null,
        val grandparentTitle: String? = null,
        val grandparentRatingKey: JsonPrimitive? = null,
        val librarySectionID: JsonPrimitive? = null,
        val parentIndex: Int? = null,
        val index: Int? = null,
        val contentRating: String? = null,
        val duration: Long? = null,
        val thumb: String? = null,
        val art: String? = null,
        @SerialName("Guid") val guids: List<Guid> = emptyList(),
        @SerialName("Media") internal val media: List<Variant> = emptyList(),
    )

    @Serializable
    data class Guid(val id: String)

    @Serializable
    data class Variant(@SerialName("Part") val parts: List<Part> = emptyList())

    @Serializable
    data class Part(
        val key: String,
        val size: Long? = null,
        val container: String? = null,
        @SerialName("Stream") val streams: List<Track> = emptyList(),
    )

    @Serializable
    data class Track(
        val streamType: Int,
        val key: String? = null,
        val codec: String? = null,
        val language: String? = null,
        val languageCode: String? = null,
        val forced: Boolean = false,
    )

    class MediaPart internal constructor(
        internal val owner: PlexMediaClient,
        internal val url: HttpUrl,
        val size: Long,
        val container: String?,
        val tracks: List<Track>,
    )

    @Serializable
    private data class Envelope<T>(@SerialName("MediaContainer") val container: T)

    @Serializable
    private data class Sections(@SerialName("Directory") val libraries: List<Library> = emptyList())

    @Serializable
    private data class Page(
        @SerialName("Metadata") val items: List<Item> = emptyList(),
        val offset: Int? = null,
        val librarySectionID: JsonPrimitive? = null,
        val totalSize: Int? = null,
        val size: Int? = null,
    )

    private val origin = connection.secureURL()?.takeIf { connection in server.secureConnections } ?: invalidResponse()
    private val token = server.accessToken?.takeIf(::validToken) ?: invalidResponse()

    suspend fun libraries(): List<Library> {
        val request = request(pathURL(listOf("library", "sections")))
        val response = json.decodeFromString<Envelope<Sections>>(exchange.body(request))
        return response.container.libraries.filter { validID(it.key) && it.title.isNotEmpty() }
    }

    suspend fun item(id: String, libraryId: String? = null): Item {
        if (!validID(id) || (libraryId != null && !validID(libraryId))) invalidResponse()
        val url = pathURL(listOf("library", "metadata", id)).newBuilder().addQueryParameter("includeGuids", "1").build()
        val page = json.decodeFromString<Envelope<Page>>(exchange.body(request(url))).container
        val item = page.items.singleOrNull()?.takeIf { it.ratingKey == id } ?: invalidResponse()
        if (libraryId != null) {
            val sections = listOfNotNull(page.librarySectionID?.content, item.librarySectionID?.content)
            if (sections.isEmpty() || sections.any { it != libraryId }) {
                throw PlexException("This item no longer belongs to the linked Plex library. Rescan its source.")
            }
        }
        return item
    }

    suspend fun image(item: Item, backdrop: Boolean, authorization: () -> Unit = {}): ByteArray {
        val requested = (if (backdrop) item.art ?: item.thumb else item.thumb ?: item.art)
            ?: throw PlexException("This item has no Plex artwork.")
        val path = requested.split('/')
        if (path.size !in 5..6 || path[0].isNotEmpty() || path[1] != "library" ||
            path[2] != "metadata" || !validID(path[3]) || path[4] !in setOf("thumb", "art", "poster", "background") ||
            (path.size == 6 && !validID(path[5]))) invalidResponse()
        authorization()
        val response = exchange.send(request(pathURL(path.drop(1))).newBuilder().header("Accept", "image/*").build(), 8 * 1024 * 1024)
        authorization()
        if (response.status != 200 || response.headers["Content-Type"]?.startsWith("image/", ignoreCase = true) != true ||
            response.data.isEmpty()) throw PlexException("Plex could not load this image.", response.status)
        return response.data
    }

    suspend fun subtitle(part: MediaPart, track: Track, authorization: () -> Unit = {}): ByteArray {
        if (part.owner !== this || track !in part.tracks || track.streamType != 3) invalidResponse()
        val path = track.key?.split('/') ?: invalidResponse()
        if (path.size != 4 || path[0].isNotEmpty() || path[1] != "library" || path[2] != "streams" ||
            !validID(path[3])) invalidResponse()
        authorization()
        val response = exchange.send(request(pathURL(path.drop(1))).newBuilder().removeHeader("Accept").build(), 1024 * 1024)
        authorization()
        if (response.status != 200 || response.data.isEmpty()) throw PlexException("Plex could not load this subtitle.", response.status)
        return response.data
    }

    suspend fun catalog(library: Library, onPage: suspend (List<Item>) -> Unit) {
        if (!validID(library.key)) invalidResponse()
        catalog(pathURL(listOf("library", "sections", library.key, "all")), onPage)
    }

    suspend fun children(item: Item, onPage: suspend (List<Item>) -> Unit) {
        if (!validID(item.ratingKey)) invalidResponse()
        catalog(pathURL(listOf("library", "metadata", item.ratingKey, "children")), onPage)
    }

    private suspend fun catalog(url: HttpUrl, onPage: suspend (List<Item>) -> Unit) {
        val pageSize = 100
        val seen = mutableSetOf<String>()
        var offset = 0
        while (offset < 250_000) {
            coroutineContext.ensureActive()
            val pageURL = url.newBuilder().addQueryParameter("includeGuids", "1").build()
            val pageRequest = request(pageURL).newBuilder().header("X-Plex-Container-Start", offset.toString())
                .header("X-Plex-Container-Size", pageSize.toString()).build()
            val page = json.decodeFromString<Envelope<Page>>(exchange.body(pageRequest)).container
            val count = page.items.size
            if (count > pageSize || page.size?.let { it != count } == true ||
                page.offset?.let { it != offset } == true || page.totalSize?.let { it < offset + count } == true ||
                page.items.any { !validID(it.ratingKey) || !seen.add(it.ratingKey) }) invalidResponse()
            if (count == 0) {
                if (page.totalSize?.let { it > offset } == true) invalidResponse()
                return
            }
            onPage(page.items)
            offset += count
            if (page.totalSize?.let { offset == it } ?: (count < pageSize)) return
        }
        invalidResponse()
    }

    fun singleFileParts(item: Item): List<MediaPart> = item.media.mapNotNull { variant ->
        val part = variant.parts.singleOrNull() ?: return@mapNotNull null
        val size = part.size?.takeIf { it > 0 } ?: return@mapNotNull null
        val path = mediaPath(part.key) ?: return@mapNotNull null
        MediaPart(this, pathURL(path), size, part.container, part.streams)
    }

    suspend fun read(part: MediaPart, offset: Long, length: Int): ByteArray {
        if (part.owner !== this || offset < 0 || offset >= part.size || length !in 1..MAXIMUM_RANGE_BYTES ||
            length > part.size - offset) invalidResponse()
        val end = offset + length - 1
        val request = request(part.url).newBuilder().removeHeader("Accept")
            .header("Accept-Encoding", "identity").header("Range", "bytes=$offset-$end").build()
        val response = exchange.send(request, length)
        if (response.status != 206) throw PlexException("Plex returned HTTP ${response.status}.", response.status)
        if (response.data.size != length || response.headers["Content-Range"] != "bytes $offset-$end/${part.size}" ||
            response.headers["Content-Encoding"]?.equals("identity", ignoreCase = true) == false) invalidResponse()
        return response.data
    }

    private fun request(url: HttpUrl): Request = plexRequest(url, deviceID).header("X-Plex-Token", token).build()

    private fun pathURL(path: List<String>): HttpUrl = origin.newBuilder().apply {
        path.forEach { addPathSegment(it) }
    }.build()

    private fun mediaPath(key: String): List<String>? {
        val parts = key.split('/')
        val suffixSegments = parts.drop(4)
        if (parts.size !in 5..6 || parts[0].isNotEmpty() || parts[1] != "library" || parts[2] != "parts" ||
            !validID(parts[3]) || suffixSegments.any {
                it == "." || it == ".." || !safeSegment.matches(it)
            }) return null
        return parts.drop(1)
    }

    private companion object {
        val safeSegment = Regex("[a-zA-Z0-9._-]{1,128}")
    }
}

private fun plexRequest(url: HttpUrl, deviceID: UUID): Request.Builder = Request.Builder().url(url)
    .header("Accept", "application/json").header("X-Plex-Product", "MediaVault")
    .header("X-Plex-Platform", "Android").header("X-Plex-Device", "Android TV")
    .header("X-Plex-Client-Identifier", deviceID.toString())

private fun validID(value: String): Boolean = value.length in 1..20 && value.all { it in '0'..'9' }
private fun validToken(value: String): Boolean = value.length in 1..4096 && value.all { it in '!'..'~' }

private suspend fun PlexExchange.body(request: Request, acceptedStatus: Set<Int> = setOf(200)): String {
    val response = send(request, MAXIMUM_CATALOG_BYTES)
    if (response.status !in acceptedStatus) throw PlexException("Plex returned HTTP ${response.status}.", response.status)
    if (response.data.size > MAXIMUM_CATALOG_BYTES) invalidResponse()
    return response.data.decodeToString()
}

private fun invalidResponse(): Nothing = throw PlexException("Plex returned an invalid media or account response.")
