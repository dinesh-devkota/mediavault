package com.dineshdevkota.cinevault.emby

import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.*
import org.junit.Test

class EmbyDraftAuthorizationTest {
    @Test
    fun discardingSetupRevokesOnlyAnUnsavedTokenAndRunsOnce() = runBlocking<Unit> {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(204))
            val endpoint = server.url("/emby/").newBuilder().host("127.0.0.1").build()
            val client = EmbyClient(endpoint.toString(), "fixture-device", "1.0",
                OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).build(), allowLoopbackHttp = true)
            val account = EmbyClient.Account("temporary-token", EmbyClient.User("user", "Test"))
            val draft = EmbyDraftAuthorization(EmbyConnection(client, account))
            val cleanup = draft.discard(this) { "saved-token" }
            assertSame(cleanup, draft.discard(this) { error("Discard should run only once") })
            cleanup.join()
            val logout = server.takeRequest()
            assertEquals("POST", logout.method)
            assertEquals("/emby/Sessions/Logout", logout.path)
            assertEquals("temporary-token", logout.getHeader("X-Emby-Token"))

            val saved = EmbyClient.Account("saved-token", account.User)
            EmbyDraftAuthorization(EmbyConnection(client, saved)).discard(this) { "saved-token" }.join()
            assertEquals(1, server.requestCount)
        }
    }
}
