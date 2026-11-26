package com.dineshdevkota.cinevault.jellyfin

import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class JellyfinSetupSessionsTest {
    @Test
    fun abandoningANewDraftSignsOutExactlyOnce() = withServer { manager, server ->
        server.enqueue(MockResponse().setResponseCode(204))
        val draft = manager.draft(server, token = "new-token")
        draft.abandon().join()
        draft.abandon().join()
        assertLogout(server, "new-token")
        assertEquals(1, server.requestCount)
    }

    @Test
    fun originalSavedAndUnreadableCredentialsArePreserved() = withServer { manager, server ->
        manager.draft(server, token = "original", original = Result.success("original")).abandon().join()
        manager.draft(server, token = "saved", saved = { it == "saved" }).abandon().join()
        manager.draft(server, token = "uncertain", original = Result.failure(IllegalStateException())).abandon().join()
        val committed = manager.draft(server, token = "committed")
        var wrote = false
        committed.save { wrote = true }
        committed.abandon().join()
        assertTrue(wrote)
        assertEquals(0, server.requestCount)
    }

    @Test
    fun oneAbandonedEditorDoesNotSignOutAnotherEditorWithTheSameToken() = withServer { manager, server ->
        server.enqueue(MockResponse().setResponseCode(204))
        val first = manager.draft(server, token = "shared")
        val second = manager.draft(server, token = "shared")
        first.abandon().join()
        assertEquals(0, server.requestCount)
        second.abandon().join()
        assertLogout(server, "shared")
        assertEquals(1, server.requestCount)
    }

    @Test
    fun failingToLoadLibrariesDisposesOfTheAuthenticatedDraft() = withServer { manager, server ->
        server.enqueue(MockResponse().setResponseCode(500))
        server.enqueue(MockResponse().setResponseCode(204))
        val draft = manager.draft(server, token = "library-lost")
        val failure = runCatching {
            draft.prepare { it.client.libraries(it.session) }
        }.exceptionOrNull() as? JellyfinException
        assertEquals(500, failure?.status)
        assertEquals("/UserViews", server.takeRequest(5, TimeUnit.SECONDS)?.requestUrl?.encodedPath)
        assertLogout(server, "library-lost")
        assertEquals(2, server.requestCount)
    }

    @Test
    fun aReconnectionToADifferentAccountDisposesOfTheNewToken() = withServer { manager, server ->
        server.enqueue(MockResponse().setResponseCode(204))
        val draft = manager.draft(server, token = "wrong-account", original = Result.success("original"))
        val failure = runCatching {
            draft.prepare {
                if (it.session.user.id != "stored-account") throw JellyfinException("Reconnect with the original account.")
            }
        }.exceptionOrNull()
        assertNotNull(failure)
        assertLogout(server, "wrong-account")
        assertEquals(1, server.requestCount)
    }

    @Test
    fun cleanupOutlivesAScreenCancelledDuringAuthentication() = withServer { manager, server ->
        server.enqueue(MockResponse().setResponseCode(204))
        val activity = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val started = CompletableDeferred<Unit>()
        val response = CompletableDeferred<Unit>()
        val request = activity.launch {
            val address = server.url("/").toString()
            manager.open(address, Result.success(null), savedToken = { false }, authorize = {}) {
                started.complete(Unit)
                response.await()
                connection(server, "late-token")
            }
        }
        started.await()
        activity.cancel()
        response.complete(Unit)
        request.join()
        assertLogout(server, "late-token")
    }

    private fun withServer(check: suspend (JellyfinSetupSessions, MockWebServer) -> Unit) = runBlocking {
        MockWebServer().use { server ->
            val app = CoroutineScope(SupervisorJob() + Dispatchers.Default)
            try { check(JellyfinSetupSessions(app), server) }
            finally { app.cancel() }
        }
    }

    private suspend fun JellyfinSetupSessions.draft(
        server: MockWebServer,
        token: String,
        original: Result<String?> = Result.success(null),
        saved: suspend (String) -> Boolean = { false },
    ): JellyfinSetupSessions.Draft =
        open(server.url("/").toString(), original, saved, authorize = {}) { connection(server, token) }

    private fun connection(server: MockWebServer, token: String): JellyfinConnection = JellyfinConnection(
        JellyfinClient(server.url("/").toString(), "setup-fixture", "1.0", allowHttpForFixture = true),
        JellyfinSession(token, JellyfinUser("fixture-account", "Fixture")),
    )

    private fun assertLogout(server: MockWebServer, token: String) {
        val request = checkNotNull(server.takeRequest(5, TimeUnit.SECONDS))
        assertEquals("POST", request.method)
        assertEquals("/Sessions/Logout", request.path)
        assertTrue(request.getHeader("Authorization").orEmpty().contains("Token=\"$token\""))
    }
}
