package com.dineshdevkota.cinevault.cloud

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
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
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class OneDriveCatalogTest {
    @Test
    fun reconnectRotatesTheStoredRefreshTokenAndScopedReadsStopAfterPermissionRevocation() = runBlocking {
        val fixture = Fixture()
        val source = UUID.randomUUID()
        val store = MemoryStore()
        val first = OneDriveAccount(source, fixture.client, store)
        first.link(first.beginSignIn())
        assertEquals("drive-id", store.load(source)?.driveId)
        assertEquals("original-refresh", store.load(source)?.refreshToken)

        // Create a fresh in-memory session using the same saved source record.
        val resumed = OneDriveAccount(source, fixture.client, store)
        var unlocked = true
        val scope = OneDriveCatalog(resumed, "root-folder",
            mayBrowse = { unlocked && "Restricted" !in it },
            mayRead = { unlocked && "Hidden.mp4" !in it })
        val files = mutableListOf<OneDriveCatalog.File>()
        scope.scan { files.add(it) }
        assertEquals(listOf(listOf("Public", "Film.mp4")), files.map { it.path })
        assertEquals("rotated-refresh", store.load(source)?.refreshToken)
        assertEquals(1, fixture.refreshes.get())
        val movie = files.single()
        assertArrayEquals("ftyp".toByteArray(), movie.read(0, 4))

        unlocked = false
        expectRejected { movie.read(0, 4) }
        assertEquals(1, fixture.reads.get())
        unlocked = true
        resumed.disconnect()
        expectRejected { movie.read(0, 4) }
        assertNull(store.load(source))
        assertEquals(1, fixture.reads.get())
    }

    @Test
    fun reconnectCannotReplaceAnExistingSourcesDriveIdentity() = runBlocking {
        val fixture = Fixture()
        val source = UUID.randomUUID()
        val store = MemoryStore()
        val account = OneDriveAccount(source, fixture.client, store)
        account.link(account.beginSignIn())
        fixture.driveId = "different-drive"
        expectRejected { account.link(account.beginSignIn()) }
        assertEquals("drive-id", store.load(source)?.driveId)
        assertEquals("original-refresh", store.load(source)?.refreshToken)
    }

    @Test
    fun disconnectInvalidatesAnInFlightRefreshWithoutRestoringTheCredential() = runBlocking {
        val entered = CompletableDeferred<Unit>()
        val release = CountDownLatch(1)
        val fixture = Fixture(beforeRefresh = {
            entered.complete(Unit)
            check(release.await(10, TimeUnit.SECONDS))
        })
        val source = UUID.randomUUID()
        val store = MemoryStore()
        val account = OneDriveAccount(source, fixture.client, store)
        store.save(source, SavedOneDriveAccount(source.toString(), CLIENT_ID, "drive-id", "original-refresh"))
        val scope = OneDriveCatalog(account, "root-folder", { true }, { true })
        val request = async {
            expectRejected { scope.scan { fail("Scan published an item after disconnect.") } }
        }
        try {
            withTimeout(5_000) { entered.await() }
            account.disconnect()
        } finally {
            release.countDown()
        }
        request.await()
        assertNull(store.load(source))
    }

    private suspend fun expectRejected(action: suspend () -> Unit) {
        try {
            action()
            fail("Expected OneDrive to reject the request")
        } catch (_: CloudClientException) {
            // The request was rejected at the provider boundary.
        }
    }

    private class MemoryStore : OneDriveAccountStore {
        private val accounts = mutableMapOf<UUID, SavedOneDriveAccount>()
        override fun load(source: UUID): SavedOneDriveAccount? = accounts[source]
        override fun save(source: UUID, account: SavedOneDriveAccount) {
            accounts[source] = account
        }
        override fun remove(source: UUID) {
            accounts.remove(source)
        }
    }

    private class Fixture(beforeRefresh: () -> Unit = {}) {
        val refreshes = AtomicInteger()
        val reads = AtomicInteger()
        @Volatile var driveId = "drive-id"
        val client = OneDriveClient(CLIENT_ID, OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request()
            when (request.url.host) {
                "login.microsoftonline.com" -> {
                    assertNull(request.header("Authorization"))
                    if (request.url.pathSegments.last() == "devicecode") {
                        response(request,
                            """{"user_code":"FIXTURE","verification_uri":"https://microsoft.com/devicelogin","device_code":"device","expires_in":60,"interval":1}""")
                    } else {
                        val form = request.body as FormBody
                        val params = (0 until form.size).associate { form.name(it) to form.value(it) }
                        if (params["grant_type"] == "refresh_token") {
                            assertEquals("original-refresh", params["refresh_token"])
                            refreshes.incrementAndGet()
                            beforeRefresh()
                            response(request, """{"access_token":"access","refresh_token":"rotated-refresh","expires_in":3600}""")
                        } else {
                            response(request, """{"access_token":"access","refresh_token":"original-refresh","expires_in":3600}""")
                        }
                    }
                }
                "graph.microsoft.com" -> {
                    assertEquals("Bearer access", request.header("Authorization"))
                    when (request.url.encodedPath) {
                        "/v1.0/me/drive" -> response(request, """{"id":"$driveId"}""")
                        "/v1.0/me/drive/items/root-folder/children" -> response(request, """
                            {"value":[
                                {"id":"public-folder","name":"Public","folder":{}},
                                {"id":"private-folder","name":"Restricted","folder":{}},
                                {"id":"shortcut","name":"Shortcut","folder":{},"remoteItem":{"id":"other"}},
                                {"id":"hidden","name":"Hidden.mp4","file":{},"size":16},
                                {"id":"script","name":"Script.ts","file":{},"size":16}
                            ]}
                        """.trimIndent())
                        "/v1.0/me/drive/items/public-folder/children" -> response(request,
                            """{"value":[{"id":"film","name":"Film.mp4","file":{},"size":16}]}""")
                        "/v1.0/me/drive/items/root-folder:/Script.ts" -> response(request,
                            """{"id":"script","name":"Script.ts","@microsoft.graph.downloadUrl":"https://fixture.example/script"}""")
                        "/v1.0/me/drive/items/root-folder:/Public/Film.mp4" -> response(request,
                            """{"id":"film","name":"Film.mp4","@microsoft.graph.downloadUrl":"https://fixture.example/film"}""")
                        else -> error("Unexpected folder or file was accessed")
                    }
                }
                "fixture.example" -> {
                    assertNull(request.header("Authorization"))
                    if (request.url.encodedPath == "/script") {
                        assertEquals("bytes=0-15", request.header("Range"))
                        response(request, "let sample = 123", 206, "bytes 0-15/16")
                    } else {
                        reads.incrementAndGet()
                        assertEquals("bytes=0-3", request.header("Range"))
                        response(request, "ftyp", 206, "bytes 0-3/16")
                    }
                }
                else -> error("Unexpected connector endpoint")
            }
        }.build())
    }

    private companion object {
        const val CLIENT_ID = "12345678-abcd-1234-1234-123456789abc"

        fun response(request: Request, body: String, code: Int = 200, range: String? = null): Response =
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(code).message("Fixture")
                .body(body.toResponseBody()).apply { range?.let { header("Content-Range", it) } }.build()
    }
}
