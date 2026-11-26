package com.dineshdevkota.cinevault.core

import java.io.ByteArrayInputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import javax.xml.parsers.SAXParserFactory
import org.xml.sax.Attributes
import org.xml.sax.InputSource
import org.xml.sax.helpers.DefaultHandler

@kotlinx.serialization.Serializable
data class LocalMediaMetadata(
    val kind: String, val title: String? = null, val plot: String? = null, val tagline: String? = null,
    val year: Int? = null, val genres: List<String> = emptyList(), val runtime: Int? = null,
    val certification: String? = null, val tmdbId: Int? = null, val showTitle: String? = null,
    val season: Int? = null, val episode: Int? = null, val collection: String? = null, val edition: String? = null,
    val certificationSpecified: Boolean = false,
)

/** Read-only metadata. Artwork URLs and executable/remote XML entities are never followed. */
object LocalMetadataParser {
    const val MAX_BYTES = 1024 * 1024
    fun parse(bytes: ByteArray): LocalMediaMetadata {
        require(bytes.size in 1..MAX_BYTES && bytes.none { it == 0.toByte() }) { "Metadata must be a UTF-8 XML file smaller than 1 MB." }
        val xml = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes)).toString()
        require(!Regex("<!\\s*(DOCTYPE|ENTITY)", RegexOption.IGNORE_CASE).containsMatchIn(xml)) { "XML entities are not supported." }
        val values = mutableMapOf<String, MutableList<String>>()
        val present = mutableSetOf<String>()
        var root = ""
        val handler = object : DefaultHandler() {
            val stack = mutableListOf<String>(); var text = StringBuilder(); var tmdbUnique = false; var count = 0
            override fun startElement(uri: String, localName: String, qName: String, attrs: Attributes) {
                val name = localName.ifBlank { qName }.lowercase()
                stack += name; text = StringBuilder()
                require(++count <= 10000) { "Metadata has too many elements." }
                require(stack.size <= 24) { "Metadata is nested too deeply." }
                if (stack.size == 1) { root = name; require(root in setOf("movie", "episodedetails", "tvshow", "season")) { "Unsupported NFO root." } }
                if (name == "uniqueid") tmdbUnique = attrs.getValue("type")?.lowercase() == "tmdb"
            }
            override fun characters(ch: CharArray, start: Int, length: Int) { text.append(ch, start, length) }
            override fun endElement(uri: String, localName: String, qName: String) {
                val name = stack.last(); val content = text.toString().trim().take(16000)
                val key = when {
                    name == "uniqueid" && tmdbUnique && stack.size == 2 -> "tmdbid"
                    name == "name" && stack.size == 3 && stack[1] == "set" -> "set"
                    stack.size == 2 -> name
                    else -> ""
                }
                if (key.isNotEmpty()) present += key
                if (key.isNotEmpty() && content.isNotEmpty()) values.getOrPut(key) { mutableListOf() }.add(content)
                stack.removeAt(stack.lastIndex); text = StringBuilder()
            }
            override fun resolveEntity(publicId: String?, systemId: String?): InputSource = throw IllegalArgumentException("External XML resources are not supported.")
        }
        val reader = SAXParserFactory.newInstance().apply { isNamespaceAware = true }.newSAXParser().xmlReader
        reader.contentHandler = handler; reader.entityResolver = handler
        reader.parse(InputSource(ByteArrayInputStream(bytes)))
        fun first(name: String) = values[name]?.firstOrNull()
        fun number(name: String, range: IntRange) = first(name)?.toIntOrNull()?.takeIf { it in range }
        val certification = (first("mpaa") ?: first("certification"))?.uppercase()?.removePrefix("US:")?.trim()?.removePrefix("RATED ")?.trim()?.takeIf {
            it in setOf("G", "PG", "PG-13", "R", "NC-17", "TV-Y", "TV-G", "TV-Y7", "TV-Y7-FV", "TV-PG", "TV-14", "TV-MA")
        }
        val year = number("year", 1800..2200) ?: (first("premiered") ?: first("aired"))?.take(4)?.toIntOrNull()?.takeIf { it in 1800..2200 }
        return LocalMediaMetadata(root, first("title"), first("plot"), first("tagline"), year,
            values["genre"].orEmpty().flatMap { it.split(Regex("\\s*[/|]\\s*")) }.map(String::trim).filter(String::isNotEmpty).distinct().take(30),
            number("runtime", 1..10000), certification, number("tmdbid", 1..Int.MAX_VALUE), first("showtitle"),
            number("season", 0..999), number("episode", 0..999), first("set"), first("edition"),
            "mpaa" in present || "certification" in present)
    }
}

/** Stable labels from filenames; the labels never claim a measured codec or resolution. */
object MediaVersions {
    fun label(path: String): String {
        val name = path.substringAfterLast('/').substringBeforeLast('.')
        val resolution = Regex("(?i)(?:^|[^a-z0-9])(2160p|1080p|720p|480p|4k)(?:$|[^a-z0-9])").find(name)?.groupValues?.get(1)
        val edition = Regex("(?i)\\{edition-([^}]+)}").find(name)?.groupValues?.get(1)
            ?: Regex("(?i)(director'?s[ ._-]*cut|extended(?:[ ._-]*cut)?|theatrical(?:[ ._-]*cut)?|unrated|remastered)").find(name)?.value?.replace(Regex("[._-]+"), " ")
        return listOfNotNull(edition, resolution?.uppercase()).joinToString(" · ").ifEmpty { "Original file" }
    }
}
