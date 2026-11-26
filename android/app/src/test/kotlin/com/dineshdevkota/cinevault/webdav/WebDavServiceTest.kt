package com.dineshdevkota.cinevault.webdav

import com.dineshdevkota.cinevault.smb.SourceConfig
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.MockResponse
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class WebDavServiceTest {
    private val address = DavAddress("https://nas.example.com:5006/media/")
    private fun entry(href: String, directory: Boolean = false, status: Int = 200) = """
        <d:response><d:href>$href</d:href><d:propstat><d:prop><d:resourcetype>${if (directory) "<d:collection/>" else ""}</d:resourcetype><d:getcontentlength>1024</d:getcontentlength></d:prop><d:status>HTTP/1.1 $status OK</d:status></d:propstat></d:response>
    """.trimIndent()
    private fun parse(body: String) = WebDavService.parseListing(
        "<d:multistatus xmlns:d=\"DAV:\">$body</d:multistatus>".toByteArray(), address, address.url("", true), "")
    private inline fun rejects(block: () -> Unit) { try { block(); fail("Expected rejection") } catch (_: IllegalArgumentException) {} catch (_: WebDavException) {} }

    @Test fun httpsAddressPreservesEncodedNamesAndPorts() {
        val url = address.url("Film #1 & Friends.mkv")
        assertEquals(5006, url.port)
        assertEquals(listOf("media", "Film #1 & Friends.mkv"), url.pathSegments)
        assertNull(url.fragment)
        assertEquals("Film #1 & Friends.mkv", address.relative("/media/Film%20%231%20%26%20Friends.mkv", address.base))
    }
    @Test fun credentialsQueryAndInsecureDefaultsAreRejected() {
        rejects { DavAddress("https://user:secret@nas.example.com/media/") }
        rejects { DavAddress("https://nas.example.com/media/?token=secret") }
        rejects { DavAddress("http://nas.example.com/media/") }
        assertEquals("http", DavAddress("http://nas.example.com/media/", true).base.scheme)
    }
    @Test fun traversalAndEncodedSeparatorsAreRejected() {
        listOf("../secret", "Movies/../secret", "Movies\\secret", "%2e%2e/secret", "bad\u0000name").forEach { rejects { address.url(it) } }
        assertNull(address.relative("/media/Movies%2Fsecret.mkv", address.base))
        assertNull(address.relative("/media/Movies%5Csecret.mkv", address.base))
    }
    @Test fun listingIgnoresSelfOutsideRootCrossOriginAndGrandchildren() {
        val result = parse(entry("/media/", true) + entry("/media/Movies/", true) + entry("https://elsewhere.example.com/media/Other/", true) +
            entry("/elsewhere/Outside/", true) + entry("/media/Movies/Child.mkv") + entry("/media/Movie.mkv"))
        assertEquals(listOf("Movies", "Movie.mkv"), result.map { it.path })
    }
    @Test fun listingPreservesCaseAndSkipsDeniedProperties() {
        assertEquals(setOf("Kids", "kids"), parse(entry("/media/", true) + entry("/media/Kids/", true) + entry("/media/kids/", true) + entry("/media/Private/", true, 403)).map { it.path }.toSet())
    }
    @Test fun listingRequiresConfirmationOfTheRequestedDirectory() {
        assertTrue(parse(entry("/media/", true)).isEmpty())
        rejects { parse(entry("/media/", true, 403)) }
        rejects { parse(entry("/media/")) }
        rejects { parse(entry("/media/Child.mkv")) }
        rejects { parse("<d:prop>${entry("/media/", true)}</d:prop>") }
        rejects { parse(entry("/media/", true) + entry("/media/", true)) }
        rejects { parse("""<d:response><d:href>/media/</d:href><d:status>HTTP/1.1 403 Forbidden</d:status></d:response>""") }
    }

    @Test fun listingDoesNotUseNestedPropertiesOrDeniedChildren() {
        val injected = entry("/media/Fake/", true).replace("<d:propstat>", "<d:ignored><d:propstat>")
            .replace("</d:propstat>", "</d:propstat></d:ignored>")
        val denied = entry("/media/Denied/", true).replace("</d:response>", "<d:status>HTTP/1.1 403 Forbidden</d:status></d:response>")
        assertTrue(parse(entry("/media/", true) + injected + denied).isEmpty())
    }

    @Test fun xmlEntitiesAndNonDavDocumentsAreRejected() {
        rejects { WebDavService.parseListing("<!DOCTYPE x [<!ENTITY steal SYSTEM 'file:///secret'>]><x>&steal;</x>".toByteArray(), address, address.base, "") }
        rejects { WebDavService.parseListing("<html>Login</html>".toByteArray(), address, address.base, "") }
        rejects { WebDavService.parseListing("<!DOCTYPE x><x/>".toByteArray(Charsets.UTF_16), address, address.base, "") }
    }
    @Test fun realRequestsBrowseAndSeekWithScopedAuthentication() = runBlocking {
        val server = MockWebServer()
        server.enqueue(MockResponse().setResponseCode(207).setBody("<d:multistatus xmlns:d=\"DAV:\">${entry("/media/", true) + entry("/media/Movies/", true)}</d:multistatus>"))
        server.enqueue(MockResponse().setResponseCode(206).setHeader("Content-Range", "bytes 0-0/10").setBody("0"))
        server.enqueue(MockResponse().setResponseCode(206).setHeader("Content-Range", "bytes 5-9/10").setBody("56789"))
        server.start()
        try {
            val config = SourceConfig("test", server.url("/media/").toString(), null, "", "", "viewer", "secret", sourceType = "webdav", allowInsecureHttp = true)
            val service = WebDavService()
            assertEquals("Movies", service.list(config).single().path)
            service.open(config, "movie.mp4").use { handle ->
                assertEquals(10L, handle.length)
                assertEquals("56789", handle.stream(5).use { String(it.readBytes()) })
                service.reset(config.id)
                rejects { handle.stream(0) }
            }
            val listing = server.takeRequest()
            assertEquals("PROPFIND", listing.method)
            assertEquals("1", listing.getHeader("Depth"))
            for (request in listOf(listing, server.takeRequest(), server.takeRequest())) {
                assertEquals("Basic dmlld2VyOnNlY3JldA==", request.getHeader("Authorization"))
            }
        } finally { server.shutdown() }
    }
    @Test fun scanAndSidecarsKeepExactCaseAcrossFolders() = runBlocking {
        MockWebServer().use { server ->
            fun listing(vararg values: String) = MockResponse().setResponseCode(207)
                .setBody("<d:multistatus xmlns:d=\"DAV:\">${values.joinToString("")}</d:multistatus>")
            val root = entry("/media/", true)
            val kids = entry("/media/Kids/", true)
            val lowercase = entry("/media/kids/", true)
            val movie = entry("/media/Kids/Film.mp4")
            val photo = entry("/media/Kids/Photo.jpg")
            val captions = entry("/media/Kids/Film.en.srt")
            val unrelated = entry("/media/Kids/film.en.srt")
            server.enqueue(listing(root, kids, lowercase))
            server.enqueue(listing(kids, movie, photo, captions, unrelated))
            server.enqueue(listing(kids, captions, unrelated))
            server.enqueue(MockResponse().setResponseCode(206).setHeader("Content-Range", "bytes 0-0/3").setBody("s"))
            server.enqueue(MockResponse().setResponseCode(206).setHeader("Content-Range", "bytes 0-2/3").setBody("srt"))
            val config = SourceConfig("test", server.url("/media/").toString(), null, "", "", "", "",
                ignoredFolders = listOf("kids"), sourceType = "webdav", allowInsecureHttp = true)
            val media = WebDavMedia()
            val scanned = media.scan(config) {}
            assertEquals(setOf("Kids/Film.mp4", "Kids/Photo.jpg"), scanned.map { it.path }.toSet())
            val subtitles = media.subtitles(config, "Kids/Film.mp4", "en")
            assertEquals(1, subtitles.files.size)
            assertEquals(listOf("/media/", "/media/Kids/", "/media/Kids/", "/media/Kids/Film.en.srt", "/media/Kids/Film.en.srt"),
                List(5) { server.takeRequest().path })
        }
    }

    @Test fun emptyFileDoesNotRequestAnInvalidRange() {
        val server = MockWebServer()
        server.enqueue(MockResponse().setResponseCode(416).setHeader("Content-Range", "bytes */0"))
        server.start()
        try {
            val config = SourceConfig("test", server.url("/media/").toString(), null, "", "", "", "", sourceType = "webdav", allowInsecureHttp = true)
            WebDavService().open(config, "empty.mp4").use { handle ->
                assertEquals(0L, handle.length)
                handle.stream(0).use { assertEquals(-1, it.read()) }
            }
            assertEquals(1, server.requestCount)
        } finally { server.shutdown() }
    }

    @Test fun sameSizeReplacementDuringSeekFails() {
        val server = MockWebServer()
        server.enqueue(MockResponse().setResponseCode(206).setHeader("Content-Range", "bytes 0-0/10")
            .setHeader("ETag", "\"old\"").setBody("0"))
        server.enqueue(MockResponse().setResponseCode(206).setHeader("Content-Range", "bytes 5-9/10")
            .setHeader("ETag", "\"new\"").setBody("56789"))
        server.start()
        try {
            val config = SourceConfig("test", server.url("/media/").toString(), null, "", "", "", "", sourceType = "webdav", allowInsecureHttp = true)
            WebDavService().open(config, "movie.mp4").use { handle -> rejects { handle.stream(5) } }
            server.takeRequest()
            assertEquals("\"old\"", server.takeRequest().getHeader("If-Match"))
        } finally { server.shutdown() }
    }

    @Test fun truncatedChunkedRangeFailsInsteadOfReturningACompleteFile() {
        val server = MockWebServer()
        server.enqueue(MockResponse().setResponseCode(206).setHeader("Content-Range", "bytes 0-0/10").setBody("0"))
        server.enqueue(MockResponse().setResponseCode(206).setHeader("Content-Range", "bytes 5-9/10").setChunkedBody("567", 2))
        server.start()
        try {
            val config = SourceConfig("test", server.url("/media/").toString(), null, "", "", "", "", sourceType = "webdav", allowInsecureHttp = true)
            WebDavService().open(config, "movie.mp4").use { handle ->
                handle.stream(5).use { stream -> rejects { stream.readBytes() } }
            }
        } finally { server.shutdown() }
    }

    @Test fun redirectAndServersIgnoringRangesFailClosed() {
        val server = MockWebServer()
        server.enqueue(MockResponse().setResponseCode(302).setHeader("Location", "/target/"))
        server.enqueue(MockResponse().setResponseCode(200).setBody("0123456789"))
        server.start()
        try {
            val config = SourceConfig("test", server.url("/redirect/").toString(), null, "", "", "", "", sourceType = "webdav", allowInsecureHttp = true)
            rejects { WebDavService().open(config, "movie.mp4") }
            rejects { WebDavService().open(config.copy(host = server.url("/target/").toString()), "movie.mp4") }
            assertEquals(2, server.requestCount)
        } finally { server.shutdown() }
    }
}
