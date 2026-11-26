package com.dineshdevkota.cinevault.cloud

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import okhttp3.FormBody
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

@OptIn(ExperimentalCoroutinesApi::class)
class OneDriveClientTest {
    @Test
    fun deviceAuthorizationHonorsPendingAndSlowDownAndRefreshesWithoutASecret() = runTest {
        val polls = AtomicInteger()
        val http = OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request()
            assertEquals("login.microsoftonline.com", request.url.host)
            assertEquals("POST", request.method)
            assertNull(request.header("Authorization"))
            val params = form(request)
            assertEquals(APP_ID, params["client_id"])
            assertNull(params["client_secret"])
            when (request.url.pathSegments.last()) {
                "devicecode" -> {
                    assertEquals(SCOPE, params["scope"])
                    response(request, CHALLENGE)
                }
                "token" -> when (params["grant_type"]) {
                    "urn:ietf:params:oauth:grant-type:device_code" -> {
                        assertEquals("device+code", params["device_code"])
                        when (polls.incrementAndGet()) {
                            1 -> response(request, """{"error":"authorization_pending"}""", 400)
                            2 -> response(request, """{"error":"slow_down"}""", 400)
                            3 -> response(request, CREDS)
                            else -> error("Unexpected poll")
                        }
                    }
                    "refresh_token" -> {
                        assertEquals("refresh+token", params["refresh_token"])
                        assertEquals(SCOPE, params["scope"])
                        response(request, """{"access_token":"renewed","refresh_token":"new-refresh","expires_in":3600}""")
                    }
                    else -> error("Unexpected grant")
                }
                else -> error("Unexpected OAuth endpoint")
            }
        }.build()
        val client = OneDriveClient(APP_ID.uppercase(), http) { currentTime }
        val challenge = client.beginSignIn()
        assertEquals("CODE", challenge.userCode)
        assertEquals("https://www.microsoft.com/link", challenge.verificationUri.toString())
        val credentials = client.completeSignIn(challenge)
        assertEquals(8_000L, currentTime)
        assertEquals(3, polls.get())
        assertEquals("access", credentials.accessToken)
        val renewed = client.refresh(requireNotNull(credentials.refreshToken))
        assertEquals("new-refresh", renewed.refreshToken)
    }

    @Test
    fun neverPollsExpiredChallengesOrOpensAnUntrustedVerificationSite() = runTest {
        val calls = AtomicInteger()
        val http = OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request()
            assertEquals("devicecode", request.url.pathSegments.last())
            if (calls.incrementAndGet() == 1) response(request, CHALLENGE)
            else response(request, CHALLENGE.replace("www.microsoft.com", "microsoft.com.invalid"))
        }.build()
        val client = OneDriveClient(APP_ID, http) { currentTime }
        val challenge = client.beginSignIn()
        advanceTimeBy(60_000)
        assertInvalid { client.completeSignIn(challenge) }
        assertEquals(1, calls.get())
        assertInvalid { client.beginSignIn() }
        assertEquals(2, calls.get())
    }

    @Test
    fun followsGraphPaginationAndFetchesFreshSignedRangesWithoutSendingTheGraphBearer() = runTest {
        val links = AtomicInteger()
        val http = OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request()
            when (request.url.host) {
                "graph.microsoft.com" -> {
                    assertEquals("Bearer access", request.header("Authorization"))
                    when (request.url.pathSegments.joinToString("/")) {
                        "v1.0/me/drive/items/folder/children" -> response(request,
                            """{"value":[{"id":"movie","name":"Film.mp4","size":16}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/drives/drive-1/items/folder/children?${'$'}skiptoken=next%2Bpage"}""")
                        "v1.0/drives/drive-1/items/folder/children" -> {
                            assertEquals("next+page", request.url.queryParameter("\$skiptoken"))
                            response(request, """{"value":[{"id":"other","name":"Other","folder":{"childCount":2}}]}""")
                        }
                        "v1.0/me/drive/items/movie" -> {
                            assertEquals("id,@microsoft.graph.downloadUrl", request.url.queryParameter("\$select"))
                            val sig = links.incrementAndGet()
                            response(request, """{"id":"movie","@microsoft.graph.downloadUrl":"https://download.fixture.example/film?sig=$sig"}""")
                        }
                        else -> error("Unexpected Graph endpoint")
                    }
                }
                "download.fixture.example" -> {
                    assertNull(request.header("Authorization"))
                    assertEquals("identity", request.header("Accept-Encoding"))
                    when (request.header("Range")) {
                        "bytes=4-7" -> {
                            assertEquals("1", request.url.queryParameter("sig"))
                            response(request, "ftyp", 206, "bytes 4-7/16")
                        }
                        "bytes=8-11" -> {
                            assertEquals("2", request.url.queryParameter("sig"))
                            response(request, "trun", 206, "bytes 8-11/16/30")
                        }
                        else -> error("Unexpected range")
                    }
                }
                else -> error("Unexpected host")
            }
        }.build()
        val client = OneDriveClient(APP_ID, http)
        val entries = mutableListOf<OneDriveClient.Entry>()
        client.listChildren("folder", "access") { entries.addAll(it) }
        assertEquals(listOf("movie", "other"), entries.map { it.id })
        assertEquals(2, entries[1].folder?.childCount)
        assertArrayEquals("ftyp".toByteArray(), client.read("movie", 4, 4, "access"))
        assertInvalid { client.read("movie", 8, 4, "access") }
        assertEquals(2, links.get())
    }

    @Test
    fun rejectsPaginationToAnotherHostOrFolderBeforeForwardingCredentials() = runTest {
        val calls = AtomicInteger()
        val http = OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request()
            assertEquals("graph.microsoft.com", request.url.host)
            assertEquals("/v1.0/me/drive/items/folder/children", request.url.encodedPath)
            val next = when (calls.incrementAndGet()) {
                1 -> "https://other.fixture.example/v1.0/me/drive/items/folder/children"
                2 -> "https://graph.microsoft.com/v1.0/drives/drive/items/other/children"
                else -> error("Unexpected continuation request")
            }
            response(request, """{"value":[],"@odata.nextLink":"$next"}""")
        }.build()
        val client = OneDriveClient(APP_ID, http)
        repeat(2) {
            assertInvalid { client.listChildren("folder", "access") {} }
        }
        assertEquals(2, calls.get())
    }

    @Test
    fun scopedReadsRejectPathReplacementAndChangesInContentRangeSize() = runTest {
        val scoped = OneDriveClient.ScopedFile("folder", listOf("Season 1", "Clip #1.mp4"), 16)
        var graphItem = "replaced"
        var total = 17
        var downloads = 0
        val client = OneDriveClient(APP_ID, OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request()
            when (request.url.host) {
                "graph.microsoft.com" -> {
                    assertEquals(listOf("v1.0", "me", "drive", "items", "folder:", "Season 1", "Clip #1.mp4"), request.url.pathSegments)
                    assertEquals("Bearer access", request.header("Authorization"))
                    response(request, """{"id":"$graphItem","name":"Clip #1.mp4","@microsoft.graph.downloadUrl":"https://fixture.example/clip"}""")
                }
                "fixture.example" -> {
                    downloads++
                    assertNull(request.header("Authorization"))
                    assertEquals("bytes=4-7", request.header("Range"))
                    response(request, "clip", code = 206, range = "bytes 4-7/$total")
                }
                else -> error("Unexpected provider origin.")
            }
        }.build())
        assertInvalid { client.read("original", 4, 4, "access", scoped) }
        assertEquals("Replacement never reaches the download host", 0, downloads)

        graphItem = "original"
        assertInvalid { client.read("original", 4, 4, "access", scoped) }
        total = 16
        assertEquals("clip", client.read("original", 4, 4, "access", scoped).decodeToString())
        assertEquals(2, downloads)
    }

    private suspend fun assertInvalid(block: suspend () -> Unit) {
        try {
            block()
            fail("Expected OneDrive to reject the request")
        } catch (_: CloudClientException) {
            // The fixture received a provider-facing validation error.
        }
    }

    private fun form(request: Request): Map<String, String> {
        val body = request.body as FormBody
        return (0 until body.size).associate { body.name(it) to body.value(it) }
    }

    private fun response(request: Request, body: String, code: Int = 200, range: String? = null): Response =
        Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(code).message("Fixture")
            .body(body.toResponseBody()).apply { range?.let { header("Content-Range", it) } }.build()

    private companion object {
        const val APP_ID = "12345678-abcd-1234-1234-123456789abc"
        const val SCOPE = "https://graph.microsoft.com/Files.Read offline_access"
        const val CHALLENGE =
            """{"user_code":"CODE","verification_uri":"https://www.microsoft.com/link","device_code":"device+code","expires_in":60,"interval":1}"""
        const val CREDS = """{"access_token":"access","refresh_token":"refresh+token","expires_in":3600}"""
    }
}
