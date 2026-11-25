package com.dineshdevkota.cinevault.webdav

import com.dineshdevkota.cinevault.smb.RemoteHandle
import com.dineshdevkota.cinevault.smb.SourceConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import okhttp3.Credentials
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.xml.sax.Attributes
import org.xml.sax.InputSource
import org.xml.sax.helpers.DefaultHandler
import java.io.ByteArrayInputStream
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import javax.xml.parsers.SAXParserFactory
import kotlin.coroutines.coroutineContext

class WebDavException(message: String, val status: Int? = null) : IOException(message)
data class DavEntry(val path: String, val directory: Boolean, val size: Long) {
    val name: String get() = path.substringAfterLast('/')
}

/** Paths stored in the library are decoded, endpoint-relative names. Decode each URL component once. */
class DavAddress(raw: String, allowHttp: Boolean = false) {
    val base: HttpUrl
    init {
        val parsed = raw.trim().toHttpUrlOrNull()
            ?: throw IllegalArgumentException("Enter a complete WebDAV address, such as https://nas.example.com:5006/media/.")
        require(raw.trim().startsWith("https://", true) || raw.trim().startsWith("http://", true)) { "Use an https:// WebDAV address." }
        require(parsed.scheme == "https" || allowHttp) { "Use an https:// WebDAV address." }
        require(parsed.username.isEmpty() && parsed.password.isEmpty() && parsed.query == null && parsed.fragment == null) {
            "Enter the server address without a username, password, query, or fragment. Use the sign-in fields below."
        }
        require(parsed.pathSegments.filter(String::isNotEmpty).all(::safeComponent)) { "The WebDAV address contains an unsafe folder path." }
        base = if (parsed.encodedPath.endsWith('/')) parsed else parsed.newBuilder().addPathSegment("").build()
    }

    fun url(path: String, directory: Boolean = false): HttpUrl {
        val parts = if (path.isEmpty()) emptyList() else path.split('/')
        require(parts.all(::safeComponent)) { "Choose a folder or file inside this WebDAV source." }
        return base.newBuilder().apply {
            parts.forEach(::addPathSegment)
            if (directory && parts.isNotEmpty()) addPathSegment("")
        }.build()
    }

    fun relative(href: String, requested: HttpUrl): String? {
        val target = requested.resolve(href) ?: return null
        if (target.scheme != base.scheme || target.host != base.host || target.port != base.port ||
            target.username.isNotEmpty() || target.password.isNotEmpty() || target.query != null || target.fragment != null) return null
        val prefix = base.pathSegments.dropLast(1)
        val parts = target.pathSegments.let { if (it.lastOrNull() == "") it.dropLast(1) else it }
        if (parts.size < prefix.size || parts.take(prefix.size) != prefix || !parts.all(::safeComponent)) return null
        return parts.drop(prefix.size).joinToString("/")
    }

    companion object {
        fun contains(path: String, root: String, allowRoot: Boolean = false): Boolean {
            val parts = if (path.isEmpty()) emptyList() else path.split('/')
            val prefix = if (root.isEmpty()) emptyList() else root.split('/')
            return parts.all(::safeComponent) && prefix.all(::safeComponent) &&
                (if (allowRoot) parts.size >= prefix.size else parts.size > prefix.size) &&
                parts.take(prefix.size) == prefix
        }

        fun safeComponent(value: String): Boolean = value.isNotEmpty() && value != "." && value != ".." &&
            value.none { it == '/' || it == '\\' || it.code < 32 || it.code == 127 } &&
            // Prevent double-decoding servers from interpreting a literal filename as traversal/separators.
            !Regex("%(?:2e|2f|5c|00)", RegexOption.IGNORE_CASE).containsMatchIn(value)
    }
}

/** Read-only WebDAV adapter. No redirects, cookie jar, trust bypass, or server-side writes. */
class WebDavService(private val client: OkHttpClient = OkHttpClient.Builder()
    .followRedirects(false).followSslRedirects(false).connectTimeout(12, TimeUnit.SECONDS)
    .readTimeout(30, TimeUnit.SECONDS).build()) {
    private val generations = java.util.concurrent.ConcurrentHashMap<String, Long>()
    fun reset(id: String) { generations.compute(id) { _, old -> (old ?: 0) + 1 } }
    private fun generation(config: SourceConfig) = generations[config.id] ?: 0L
    private fun check(config: SourceConfig, generation: Long) {
        if (generation(config) != generation) throw WebDavException("The connection changed. Try again.")
    }
    private fun address(config: SourceConfig) = DavAddress(config.host, config.allowInsecureHttp)
    private fun request(config: SourceConfig, url: HttpUrl): Request.Builder = Request.Builder().url(url)
        .header("Accept-Encoding", "identity").apply {
            if (config.username.isNotEmpty()) header("Authorization", Credentials.basic(config.username, config.password, Charsets.UTF_8))
        }

    private fun execute(request: Request, allowEmptyFile: Boolean = false): Response {
        val response = client.newCall(request).execute()
        if (response.code in 200..299 ||
            allowEmptyFile && response.code == 416 && response.header("Content-Range") == "bytes */0") return response
        val code = response.code
        response.close()
        throw WebDavException(when (code) {
            401 -> "The WebDAV server rejected the username or password."
            403 -> "This account cannot open that folder. Check its WebDAV read permissions."
            404 -> "WebDAV folder or file not found. Check the full server address."
            in 300..399 -> "The server redirected this address. Enter its final WebDAV address to keep your sign-in secure."
            412 -> "The file changed. Rescan and retry."
            405, 501 -> "This address does not support WebDAV folder browsing. Check that WebDAV is enabled."
            else -> "The WebDAV server could not complete the request (HTTP $code)."
        }, code)
    }

    suspend fun list(config: SourceConfig, path: String = config.rootPath): List<DavEntry> = withContext(Dispatchers.IO) {
        coroutineContext.ensureActive()
        if (!DavAddress.contains(path, config.rootPath, allowRoot = true)) throw WebDavException("Choose a folder inside this WebDAV source.")
        val token = generation(config)
        val address = address(config)
        val url = address.url(path, directory = true)
        val result = execute(request(config, url).header("Depth", "1")
            .method("PROPFIND", PROPERTIES.toRequestBody("application/xml; charset=utf-8".toMediaType())).build()).use { response ->
            if (response.code != 207) throw WebDavException("This address did not return a WebDAV folder listing.")
            val bytes = response.body?.byteStream()?.use { it.readNBytesBounded(MAX_LISTING) }
                ?: throw WebDavException("The server returned an empty folder listing.")
            parseListing(bytes, address, url, path)
        }
        coroutineContext.ensureActive(); check(config, token)
        result
    }

    fun open(config: SourceConfig, path: String): RemoteHandle {
        if (!DavAddress.contains(path, config.rootPath)) throw WebDavException("Choose a file inside this WebDAV source.")
        val token = generation(config)
        val url = address(config).url(path)
        // A one-byte range works on servers which disable HEAD and proves seeking before playback.
        val (length, etag) = execute(
            request(config, url).header("Range", "bytes=0-0").get().build(),
            allowEmptyFile = true,
        ).use { response ->
            val size = if (response.code == 416) 0L else validateRange(response, 0, 1).also {
                val input = response.body?.byteStream() ?: throw WebDavException("The server returned no file data.")
                if (input.read() < 0) throw WebDavException("The file ended unexpectedly.")
            }
            size to response.header("ETag")?.takeIf { it.startsWith('"') && it.endsWith('"') }
        }
        check(config, token)
        return object : RemoteHandle {
            override val length = length
            private val closed = AtomicBoolean()
            private val streams = java.util.Collections.synchronizedList(mutableListOf<InputStream>())
            override fun stream(position: Long): InputStream {
                check(config, token)
                if (closed.get()) throw WebDavException("The file is closed.")
                require(position in 0..length) { "Invalid playback position." }
                if (position == length) return ByteArrayInputStream(byteArrayOf())
                val range = request(config, url).header("Range", "bytes=$position-${length - 1}")
                if (etag != null) range.header("If-Match", etag)
                val response = execute(range.get().build())
                try {
                    val receivedTag = response.header("ETag")
                    if (validateRange(response, position, length - position) != length ||
                        (etag != null && receivedTag != null && etag != receivedTag)) {
                        throw WebDavException("The file changed. Rescan and retry.")
                    }
                    check(config, token)
                    val body = response.body ?: throw WebDavException("The server returned no file data.")
                    val stream = object : FilterInputStream(body.byteStream()) {
                        private var remaining = length - position

                        override fun read(): Int {
                            check(config, token)
                            if (remaining == 0L) return -1
                            val byte = super.read()
                            consumed(if (byte < 0) -1 else 1)
                            return byte
                        }

                        override fun read(b: ByteArray, off: Int, len: Int): Int {
                            if (off < 0 || len < 0 || off > b.size - len) throw IndexOutOfBoundsException()
                            check(config, token)
                            if (len == 0) return 0
                            if (remaining == 0L) return -1
                            return super.read(b, off, minOf(len.toLong(), remaining).toInt()).also(::consumed)
                        }

                        override fun skip(n: Long): Long {
                            check(config, token)
                            val skipped = super.skip(n.coerceIn(0, remaining))
                            remaining -= skipped
                            check(config, token)
                            return skipped
                        }

                        private fun consumed(count: Int) {
                            check(config, token)
                            if (count < 0) throw WebDavException("The file ended unexpectedly.")
                            remaining -= count
                        }

                        override fun markSupported(): Boolean = false

                        override fun close() {
                            response.close()
                            streams.remove(this)
                        }
                    }
                    synchronized(streams) {
                        if (closed.get()) { stream.close(); throw WebDavException("The file is closed.") }
                        streams += stream
                    }
                    return stream
                } catch (error: Exception) { response.close(); throw error }
            }
            override fun close() { closed.set(true); synchronized(streams) { streams.toList().forEach { runCatching { it.close() } }; streams.clear() } }
        }
    }

    companion object {
        const val MAX_LISTING = 8 * 1024 * 1024
        private const val PROPERTIES = "<?xml version=\"1.0\" encoding=\"utf-8\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>"
        fun validateRange(response: Response, offset: Long, length: Long): Long {
            if (response.code != 206 || response.header("Content-Encoding")?.let { it != "identity" } == true)
                throw WebDavException("This WebDAV server must support byte-range requests for playback and seeking.")
            val match = Regex("bytes (\\d+)-(\\d+)/(\\d+)").matchEntire(response.header("Content-Range").orEmpty())
                ?: throw WebDavException("The server returned an invalid playback range.")
            val start = match.groupValues[1].toLongOrNull(); val end = match.groupValues[2].toLongOrNull(); val total = match.groupValues[3].toLongOrNull()
            if (start != offset || end == null || total == null || total <= 0 || length <= 0 ||
                offset > Long.MAX_VALUE - length || end != offset + length - 1 || end >= total ||
                response.body?.contentLength()?.let { it >= 0 && it != length } == true)
                throw WebDavException("The server returned an invalid playback range.")
            return total
        }

        fun parseListing(bytes: ByteArray, address: DavAddress, requested: HttpUrl, directory: String): List<DavEntry> {
            if (bytes.size > MAX_LISTING || bytes.any { it == 0.toByte() } ||
                bytes.toString(Charsets.UTF_8).contains(Regex("<!\\s*(DOCTYPE|ENTITY)", RegexOption.IGNORE_CASE)))
                throw WebDavException("The WebDAV folder listing is unsafe or too large.")
            val result = linkedMapOf<String, DavEntry>()
            val handler = object : DefaultHandler() {
                var rootSeen = false
                var directorySeen = false
                private var responses = 0
                private var href: String? = null
                private var responseStatus: String? = null
                private var status = ""
                private var isDir = false
                private var size = 0L
                private var propertyDir = false
                private var propertySize = 0L
                private var propertiesSucceeded = false
                private val stack = mutableListOf<String>()
                private val text = StringBuilder()
                private val responsePath = "/multistatus/response"
                private val propstatPath = "$responsePath/propstat"
                private val propertyPath = "$propstatPath/prop"
                private val success = Regex("HTTP/\\S+ 200(?: .*)?")
                private val elementPath: String get() = stack.joinToString("/", prefix = "/")

                override fun startElement(uri: String, localName: String, qName: String, attributes: Attributes) {
                    stack += if (uri == "DAV:") localName else "?"
                    text.clear()
                    if (stack.size > 32) throw WebDavException("The WebDAV folder listing is nested too deeply.")
                    when (elementPath) {
                        "/multistatus" -> rootSeen = true
                        responsePath -> {
                            href = null
                            responseStatus = null
                            isDir = false
                            size = 0
                            propertiesSucceeded = false
                            if (++responses > 100000) throw WebDavException("This folder has too many entries.")
                        }
                        propstatPath -> {
                            status = ""
                            propertyDir = false
                            propertySize = 0
                        }
                        "$propertyPath/resourcetype/collection" -> propertyDir = true
                    }
                }

                override fun characters(ch: CharArray, start: Int, length: Int) {
                    text.append(ch, start, length)
                }

                override fun endElement(uri: String, localName: String, qName: String) {
                    val value = text.toString().trim()
                    when (elementPath) {
                        "$responsePath/href" -> {
                            if (href != null) throw WebDavException("The server returned multiple addresses for one entry.")
                            href = value
                        }
                        "$responsePath/status" -> responseStatus = value
                        "$propstatPath/status" -> status = value
                        "$propertyPath/getcontentlength" -> propertySize = value.toLongOrNull()?.coerceAtLeast(0) ?: 0
                        propstatPath -> if (success.matches(status)) {
                            propertiesSucceeded = true
                            isDir = isDir || propertyDir
                            size = maxOf(size, propertySize)
                        }
                        responsePath -> acceptResponse()
                    }
                    stack.removeAt(stack.lastIndex)
                    text.clear()
                }

                private fun acceptResponse() {
                    val path = href?.takeIf(String::isNotBlank)?.let { address.relative(it, requested) } ?: return
                    val successful = propertiesSucceeded && (responseStatus?.let(success::matches) ?: true)
                    if (path == directory) {
                        if (!successful || !isDir || directorySeen) {
                            throw WebDavException("The server did not confirm read access to this WebDAV folder.")
                        }
                        directorySeen = true
                    } else if (successful && path.substringBeforeLast('/', "") == directory) {
                        val entry = DavEntry(path, isDir, size)
                        if (result.putIfAbsent(path, entry)?.let { it != entry } == true) {
                            throw WebDavException("The server returned conflicting folder entries.")
                        }
                    }
                }

                override fun resolveEntity(publicId: String?, systemId: String?): InputSource = throw WebDavException("External XML resources are not supported.")
            }
            try {
                val factory = SAXParserFactory.newInstance().apply { isNamespaceAware = true }
                // Entity declarations are rejected above; the resolver independently rejects external resources.
                val reader = factory.newSAXParser().xmlReader
                reader.contentHandler = handler; reader.entityResolver = handler
                reader.parse(InputSource(ByteArrayInputStream(bytes)))
                if (!handler.rootSeen || !handler.directorySeen) throw WebDavException("This address did not return a WebDAV folder listing.")
            } catch (error: WebDavException) { throw error }
            catch (_: Exception) { throw WebDavException("The WebDAV folder listing could not be read.") }
            return result.values.sortedWith(compareByDescending<DavEntry> { it.directory }.thenBy { it.name.lowercase() })
        }

        private fun InputStream.readNBytesBounded(limit: Int): ByteArray {
            val output = java.io.ByteArrayOutputStream(); val buffer = ByteArray(8192)
            while (true) { val count = read(buffer); if (count < 0) break
                if (output.size() + count > limit) throw WebDavException("This folder listing is too large. Choose a smaller media folder.")
                output.write(buffer, 0, count)
            }
            return output.toByteArray()
        }
    }
}
