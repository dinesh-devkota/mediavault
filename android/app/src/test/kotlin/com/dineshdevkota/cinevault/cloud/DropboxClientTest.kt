package com.dineshdevkota.cinevault.cloud

import kotlinx.coroutines.runBlocking
import okhttp3.FormBody
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class DropboxClientTest {
    @Test
    fun exchangesManualAuthorizationWithoutARedirectOrClientSecret() {
        val client = DropboxClient("fixture-app", OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request()
            assertEquals("https://api.dropboxapi.com/oauth2/token", request.url.toString())
            val body = request.body as FormBody
            val fields = (0 until body.size).associate { body.name(it) to body.value(it) }
            assertEquals("fixture-app", fields["client_id"])
            assertEquals("fixture+code", fields["code"])
            assertEquals("authorization_code", fields["grant_type"])
            assertEquals(43, fields["code_verifier"]?.length)
            assertNull(fields["redirect_uri"])
            assertNull(fields["client_secret"])
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("Fixture")
                .body("""{"access_token":"fixture","refresh_token":"refresh","expires_in":14400}""".toResponseBody())
                .build()
        }.build())
        val approval = client.beginAuthorization()
        assertEquals("www.dropbox.com", approval.url.host)
        assertEquals("S256", approval.url.queryParameter("code_challenge_method"))
        assertEquals("offline", approval.url.queryParameter("token_access_type"))
        assertNull(approval.url.queryParameter("redirect_uri"))
        assertNotEquals(approval.url.queryParameter("code_challenge"), client.beginAuthorization().url.queryParameter("code_challenge"))
        val credentials = runBlocking { client.completeAuthorization(approval, "fixture+code") }
        assertEquals("refresh", credentials.refreshToken)
        assertThrows(IllegalArgumentException::class.java) {
            runBlocking { DropboxClient("different-app").completeAuthorization(approval, "fixture+code") }
        }
    }

    @Test
    fun catalogFollowsAnEmptyPageAndFilesUseTheContentEndpoint() {
        val client = DropboxClient("fixture-app", OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request()
            assertEquals("POST", request.method)
            assertEquals("Bearer fixture", request.header("Authorization"))
            val base = Response.Builder().request(request).protocol(Protocol.HTTP_1_1).message("Fixture")
            when (request.url.encodedPath) {
                "/2/files/list_folder" -> base.code(200).body(
                    """{"entries":[],"cursor":"next","has_more":true}""".toResponseBody()
                ).build()
                "/2/files/list_folder/continue" -> base.code(200).body(
                    """{"entries":[{".tag":"file","name":"Film.mp4","id":"id:media"}],"cursor":"end","has_more":false}""".toResponseBody()
                ).build()
                "/2/files/download" -> {
                    assertEquals("content.dropboxapi.com", request.url.host)
                    assertEquals("""{"path":"id:media"}""", request.header("Dropbox-API-Arg"))
                    assertEquals("identity", request.header("Accept-Encoding"))
                    when (request.header("Range")) {
                        "bytes=5-9" -> base.code(206).header("Content-Range", "bytes 5-9/10").body("56789".toResponseBody()).build()
                        "bytes=2-6" -> base.code(206).header("Content-Range", "bytes 2-6/10").body("23".toResponseBody()).build()
                        else -> error("Unexpected range")
                    }
                }
                else -> error("Unexpected API endpoint")
            }
        }.build())
        val entries = mutableListOf<DropboxClient.Entry>()
        runBlocking { client.listFolder("", "fixture") { entries.addAll(it) } }
        val id = requireNotNull(entries.single().id)
        val data = runBlocking { client.read(id, 5, 5, "fixture") }
        assertArrayEquals("56789".toByteArray(), data)
        assertThrows(CloudClientException::class.java) { runBlocking { client.read(id, 2, 5, "fixture") } }
        assertThrows(IllegalArgumentException::class.java) { runBlocking { client.read("/wrong", 0, 1, "fixture") } }
    }

    @Test
    fun scopedRangeRequiresTheOriginalIdentityRevisionAndLength() {
        val path = "/Movies/Café.mp4"
        val expected = DropboxClient.Entry("file", "Café.mp4", "id:media", path, 10, "abc123def")
        val client = DropboxClient("fixture-app", OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request()
            val argument = requireNotNull(request.header("Dropbox-API-Arg"))
            assertTrue(argument.all { it.code < 127 })
            assertEquals(path, kotlinx.serialization.json.Json.decodeFromString<Map<String, String>>(argument)["path"])
            val revision = if (request.header("Range") == "bytes=5-9") "abc123def" else "def123abc"
            val start = if (revision == "abc123def") 5 else 0
            val result = """{"name":"Caf\u00e9.mp4","path_display":"/Movies/Caf\u00e9.mp4","id":"id:media","size":10,"rev":"$revision"}"""
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(206).message("Fixture")
                .header("Content-Range", "bytes $start-${start + 4}/10").header("Dropbox-API-Result", result)
                .body("abcde".toResponseBody()).build()
        }.build())
        assertArrayEquals("abcde".toByteArray(), runBlocking { client.read(expected, 5, 5, "fixture") })
        assertThrows(CloudClientException::class.java) { runBlocking { client.read(expected, 0, 5, "fixture") } }
    }

    @Test
    fun refreshRetriesOnceAndLeavesDropboxFolderBoundariesIntact() = runBlocking {
        val calls = java.util.concurrent.atomic.AtomicInteger()
        val client = DropboxClient("fixture-app", OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request()
            val result = """{"access_token":"fixture-${calls.incrementAndGet()}","expires_in":14400}"""
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("Fixture")
                .body(result.toResponseBody()).build()
        }.build())
        val access = DropboxAccess(client, "fixture-refresh")
        val read = access.run({}) { token -> if (token == "fixture-1") throw CloudClientException("Expired", 401) else token }
        assertEquals("fixture-2", read)
        assertEquals("fixture-2", access.run({}) { it })
        assertEquals(2, calls.get())
        assertTrue(DropboxPath.contains("Media/Film.mp4", "media"))
        assertFalse(DropboxPath.contains("MediaPrivate/Film.mp4", "media"))
        assertFalse(DropboxPath.contains("Media/../Film.mp4", "media"))
    }
}
