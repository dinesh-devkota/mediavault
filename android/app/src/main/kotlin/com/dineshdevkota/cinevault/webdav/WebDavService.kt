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
        require(parsed.scheme == "https" || allowHttp) { "Enable unencrypted HTTP only for a trusted network, or use HTTPS." }
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

    private fun execute(request: Request): Response {
        val response = client.newCall(request).execute()
        if (response.code in 200..299) return response
        val code = response.code
        response.close()
        throw WebDavException(when (code) {
            401 -> "The WebDAV server rejected the username or password."
            403 -> "This account cannot open that folder. Check its WebDAV read permissions."
            404 -> "WebDAV folder or file not found. Check the full server address."
            in 300..399 -> "The server redirected this address. Enter its final WebDAV address to keep your sign-in secure."
            405, 501 -> "This address does not support WebDAV folder browsing. Check that WebDAV is enabled."
            else -> "The WebDAV server could not complete the request (HTTP $code)."
        }, code)
    }

    suspend fun list(config: SourceConfig, path: String = config.rootPath): List<DavEntry> = withContext(Dispatchers.IO) {
        coroutineContext.ensureActive()
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
        val token = generation(config)
        val url = address(config).url(path)
        // A one-byte range works on servers which disable HEAD and proves seeking before playback.
        val length = execute(request(config, url).header("Range", "bytes=0-0").get().build()).use { response ->
            validateRange(response, 0, 1).also {
                val input = response.body?.byteStream() ?: throw WebDavException("The server returned no file data.")
                if (input.read() < 0) throw WebDavException("The file ended unexpectedly.")
            }
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
                val response = execute(request(config, url).header("Range", "bytes=$position-${length - 1}").get().build())
                try {
                    if (validateRange(response, position, length - position) != length) throw WebDavException("The file changed. Rescan and retry.")
                    check(config, token)
                    val body = response.body ?: throw WebDavException("The server returned no file data.")
                    val stream = object : FilterInputStream(body.byteStream()) {
                        override fun read(): Int { check(config, token); return super.read().also { check(config, token) } }
                        override fun read(b: ByteArray, off: Int, len: Int): Int {
                            check(config, token); return super.read(b, off, len).also { check(config, token) }
                        }
                        override fun close() { response.close() }
                    }
                    synchronized(streams) {
                        if (closed.get()) { stream.close(); throw WebDavException("The file is closed.") }
                        streams += stream
                    }
                    return stream
                } catch (error: Exception) { response.close(); throw error }
            }
            override fun close() { closed.set(true); synchronized(streams) { streams.forEach { runCatching { it.close() } }; streams.clear() } }
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
                var href = ""; var isDir = false; var size = 0L; var status = ""; var propertyDir = false; var propertySize = 0L
                var inResponse = false; var inPropstat = false; var rootSeen = false; var responseCount = 0; var propertiesSucceeded = false
                val stack = mutableListOf<String>(); var text = StringBuilder()
                override fun startElement(uri: String, localName: String, qName: String, attributes: Attributes) {
                    stack += if (uri == "DAV:") localName else "?"; text = StringBuilder()
                    if (stack.size == 1 && uri == "DAV:" && localName == "multistatus") rootSeen = true
                    if (uri != "DAV:") return
                    when (localName) {
                        "response" -> { inResponse = true; href = ""; isDir = false; size = 0; propertiesSucceeded = false; responseCount++; if (responseCount > 100000) throw WebDavException("This folder has too many entries.") }
                        "propstat" -> { inPropstat = true; status = ""; propertyDir = false; propertySize = 0 }
                        "collection" -> if (inPropstat && stack.getOrNull(stack.lastIndex - 1) == "resourcetype") propertyDir = true
                    }
                }
                override fun characters(ch: CharArray, start: Int, length: Int) { text.append(ch, start, length) }
                override fun endElement(uri: String, localName: String, qName: String) {
                    val value = text.toString().trim()
                    if (uri == "DAV:") when (localName) {
                        "href" -> if (inResponse && !inPropstat) href = value
                        "status" -> if (inPropstat) status = value
                        "getcontentlength" -> if (inPropstat) propertySize = value.toLongOrNull()?.coerceAtLeast(0) ?: 0
                        "propstat" -> { if (Regex("HTTP/\\S+ 200(?: .*)?").matches(status)) { propertiesSucceeded = true; isDir = isDir || propertyDir; size = maxOf(size, propertySize) }; inPropstat = false }
                        "response" -> {
                            inResponse = false
                            val path = address.relative(href, requested)
                            val parent = path?.substringBeforeLast('/', "")
                            if (propertiesSucceeded && !href.isBlank() && path != null && path != directory && parent == directory) {
                                val entry = DavEntry(path, isDir, size)
                                if (result.putIfAbsent(path, entry)?.let { it != entry } == true) throw WebDavException("The server returned conflicting folder entries.")
                            }
                        }
                    }
                    stack.removeAt(stack.lastIndex); text = StringBuilder()
                }
                override fun resolveEntity(publicId: String?, systemId: String?): InputSource = throw WebDavException("External XML resources are not supported.")
            }
            try {
                val factory = SAXParserFactory.newInstance().apply { isNamespaceAware = true }
                // Entity declarations are rejected above; the resolver independently rejects external resources.
                val reader = factory.newSAXParser().xmlReader
                reader.contentHandler = handler; reader.entityResolver = handler
                reader.parse(InputSource(ByteArrayInputStream(bytes)))
                if (!handler.rootSeen) throw WebDavException("This address did not return a WebDAV folder listing.")
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
