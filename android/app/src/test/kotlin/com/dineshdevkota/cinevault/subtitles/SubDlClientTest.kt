package com.dineshdevkota.cinevault.subtitles

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.*
import org.junit.Test

class SubDlClientTest {
    private val movie = SubDlSearchQuery(27205, SubDlMediaType.MOVIE)

    @Test fun searchUsesBearerAndExactIdentityQuery() = runTest {
        val client = SubDlClient { request, maximum ->
            assertEquals(2 * 1_024 * 1_024, maximum)
            assertEquals("api.subdl.com", request.url.host)
            assertEquals("/api/v2/subtitles/search", request.url.encodedPath)
            assertEquals("Bearer test-secret", request.header("Authorization"))
            assertFalse(request.url.toString().contains("test-secret"))
            assertEquals("27205", request.url.queryParameter("tmdb_id"))
            assertEquals("movie", request.url.queryParameter("type"))
            assertEquals("en", request.url.queryParameter("languages"))
            assertEquals("1", request.url.queryParameter("unpack"))
            assertEquals("0", request.url.queryParameter("full_season"))
            assertEquals("1", request.url.queryParameter("releases"))
            assertEquals("custom_integration", request.url.queryParameter("client"))
            assertEquals("30", request.url.queryParameter("subs_per_page"))
            SubDlHttpResponse(200, request.url.toString(), fixture().toByteArray())
        }
        val result = client.search(movie, "test-secret").single()
        assertEquals("en", result.language)
        assertEquals("srt", result.format)
        assertEquals(23.976, result.fps!!, 0.0001)
        assertTrue(result.releaseNames.contains("Alternate.Release"))
    }

    @Test fun neverUsesMatchingSecondIdentityOrWrongMediaType() = runTest {
        val second = fixture(identities = """{"tmdb_id":9,"type":"movie"},{"tmdb_id":27205,"type":"movie"}""")
        expect(SubDlFailure.NO_RESULTS) { client(second).search(movie, "key") }
        val wrongType = fixture(identities = """{"tmdb_id":27205,"type":"tv"}""")
        expect(SubDlFailure.NO_RESULTS) { client(wrongType).search(movie, "key") }
    }

    @Test fun tvUsesExactIndividualFileEpisodeAndRejectsAmbiguousPack() = runTest {
        val files = listOf(file("right", 1, 2), file("wrong", 1, 20),
            file("ambiguous", 1, 2).replace("\"episode\":2,", "")).joinToString(",")
        val data = fixture(files, """{"tmdb_id":42,"type":"tv"}""").toByteArray()
        val client = SubDlClient { request, _ ->
            assertEquals("1", request.url.queryParameter("season"))
            assertEquals("2", request.url.queryParameter("episode"))
            SubDlHttpResponse(200, request.url.toString(), data)
        }
        val result = client.search(SubDlSearchQuery(42, SubDlMediaType.TV, 1, 2), "key")
        assertEquals(listOf("https://dl.subdl.com/subtitle/parent/right"), result.map { it.downloadUrl })
    }

    @Test fun filtersLanguagesFormatsAndMismatchedFileIdentifiers() = runTest {
        val files = listOf(file(), file("french", language = "FR"), file("archive", format = "zip"),
            file("wrong-id", url = "/subtitle/parent/other-id")).joinToString(",")
        assertEquals(1, client(fixture(files)).search(movie, "key").size)
    }

    @Test fun unsafeLinksAndArchiveRoutesAreRejected() {
        val unsafe = listOf("http://dl.subdl.com/subtitle/p/f", "https://evil.example/subtitle/p/f",
            "https://dl.subdl.com.evil.example/subtitle/p/f", "https://user@dl.subdl.com/subtitle/p/f",
            "https://dl.subdl.com:443/subtitle/p/f", "//evil.example/subtitle/p/f",
            "/subtitle/p/f?api_key=secret", "/subtitle/p/f#part", "/subtitle/p.zip",
            "/subtitle/p/%2e%2e", "/subtitle/../f", "/subtitle/p/f/extra")
        unsafe.forEach { assertNull(it, SubDlClient.safeDownloadUrl(it)) }
        assertEquals("https://dl.subdl.com/subtitle/parent/file_1", SubDlClient.safeDownloadUrl("/subtitle/parent/file_1"))
    }

    @Test fun downloadsAreAnonymousAndBounded() = runTest {
        val data = "1\n00:00:00,000 --> 00:00:01,000\nHello\n".toByteArray()
        val client = SubDlClient { request, maximum ->
            assertEquals("dl.subdl.com", request.url.host)
            assertNull(request.header("Authorization"))
            assertNull(request.header("Cookie"))
            assertNull(request.url.query)
            assertEquals(SubDlClient.MAXIMUM_BYTES, maximum)
            SubDlHttpResponse(200, request.url.toString(), data)
        }
        assertArrayEquals(data, client.download(subtitle()))
        expect(SubDlFailure.TOO_LARGE) {
            clientBytes(ByteArray(SubDlClient.MAXIMUM_BYTES + 1)).download(subtitle())
        }
        expect(SubDlFailure.INVALID_RESPONSE) { clientBytes(byteArrayOf(0x50, 0x4b, 3, 4)).download(subtitle()) }
    }

    @Test fun rejectsRedirectsOrChangedFinalHost() = runTest {
        expect(SubDlFailure.UNSAFE_DOWNLOAD) { client("", 302).download(subtitle()) }
        val redirected = SubDlClient { _, _ -> SubDlHttpResponse(200, "https://evil.example/file", byteArrayOf(1)) }
        expect(SubDlFailure.UNSAFE_DOWNLOAD) { redirected.download(subtitle()) }
    }

    @Test fun keyValidationRequiresAccountAndUsesOnlyHeader() = runTest {
        val client = SubDlClient { request, _ ->
            assertEquals("/api/v2/me", request.url.encodedPath)
            assertNull(request.url.query)
            assertEquals("Bearer key", request.header("Authorization"))
            SubDlHttpResponse(200, request.url.toString(), """{"plan":{"name":"Free"},"usage":{"search":{}}}""".toByteArray())
        }
        client.validateKey("key")
        expect(SubDlFailure.INVALID_RESPONSE) { client("{}").validateKey("key") }
        expect(SubDlFailure.INVALID_KEY) { client.validateKey("key\r\nHeader: injected") }
    }

    @Test fun errorsNeverExposeProviderBodyOrRequestSecret() = runTest {
        for ((status, failure) in listOf(401 to SubDlFailure.INVALID_KEY, 403 to SubDlFailure.INVALID_KEY,
            429 to SubDlFailure.QUOTA, 500 to SubDlFailure.CONNECTION)) {
            expect(failure) { client("secret-key http://nas/password", status).validateKey("key") }
            assertFalse(SubDlException(failure).message!!.contains("secret-key"))
        }
        expect(SubDlFailure.QUOTA) {
            client("""{"error":{"code":"quota_exceeded","message":"secret-key"}}""").validateKey("key")
        }
    }

    @Test fun cancellationPropagatesAndInvalidQueryNeverReachesNetwork() = runTest {
        val client = SubDlClient { _, _ -> throw CancellationException("test") }
        try { client.validateKey("key"); fail("Expected cancellation") }
        catch (_: CancellationException) { }
        expect(SubDlFailure.INVALID_QUERY) { client.search(SubDlSearchQuery(42, SubDlMediaType.TV), "key") }
        expect(SubDlFailure.INVALID_QUERY) { client.search(movie.copy(language = "en,fr"), "key") }
        expect(SubDlFailure.MISSING_KEY) { client.validateKey(" ") }
    }

    private suspend fun expect(failure: SubDlFailure, action: suspend () -> Any?) {
        try { action(); fail("Expected $failure") }
        catch (error: SubDlException) { assertEquals(failure, error.failure) }
    }

    private fun client(body: String, status: Int = 200) = clientBytes(body.toByteArray(), status)
    private fun clientBytes(data: ByteArray, status: Int = 200) = SubDlClient { request, _ ->
        SubDlHttpResponse(status, request.url.toString(), data)
    }
    private fun subtitle() = SubDlSubtitle("file", "en", "Release", "srt", false,
        "https://dl.subdl.com/subtitle/parent/file", null)

    private fun file(id: String = "file", season: Int = 0, episode: Int = 0, language: String = "EN",
                     format: String = "srt", url: String = "/subtitle/parent/$id"): String =
        """{"file_n_id":${JsonPrimitive(id)},"language":${JsonPrimitive(language)},"format":${JsonPrimitive(format)},"season":$season,"episode":$episode,"release_name":"Exact.Release","size":100,"hi":true,"url":${JsonPrimitive(url)}}"""

    private fun fixture(files: String = file(), identities: String = """{"tmdb_id":27205,"type":"movie"}""") =
        """{"status":true,"results":[$identities],"subtitles":[{"release_name":"Archive","fps":"23.976","releases":["Alternate.Release"],"unpack_files":[$files],"url":"/subtitle/archive.zip"}]}"""
}
