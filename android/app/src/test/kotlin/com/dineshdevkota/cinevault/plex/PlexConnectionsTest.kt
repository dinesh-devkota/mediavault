package com.dineshdevkota.cinevault.plex

import java.util.UUID
import kotlinx.coroutines.runBlocking
import okhttp3.Headers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Test

class PlexConnectionsTest {
    private val device = UUID.randomUUID()
    private val initialOwner = UUID.randomUUID()
    private var owner: UUID? = initialOwner
    private var time = 0L
    private var requests = 0
    private var linked = false
    private val storage = MemoryStorage()

    @Test
    fun ownerChoosesADiscoveredEndpointBeforeSavingOnlyTheServerCredential() = runBlocking {
        val manager = manager()
        assertEquals(PlexConnectionManager.LinkCode("ABCD", 10), manager.start())
        assertEquals(PlexConnectionManager.LinkStatus.AwaitingAuthorization, manager.poll())
        assertNull(manager.selected())

        linked = true
        val choice = (manager.poll() as PlexConnectionManager.LinkStatus.ChooseServer).servers.single()
        val connection = choice.connections.single()
        assertEquals("Home", choice.name)
        assertEquals(endpoint, connection.endpoint)
        reject { manager.select(choice.id, "https://wrong.example:32400") }
        assertNull(storage.saved)

        val selection = manager.select(choice.id, connection.endpoint)
        assertEquals(listOf("Movies"), selection.libraries.map { it.title })
        assertEquals(selection.server, manager.selected())
        assertEquals("server-token", storage.saved?.serverToken)
        assertEquals(device.toString(), storage.saved?.deviceID)
        assertEquals(1, storage.writes)

        manager.start()
        manager.cancelLink()
        reject { manager.poll() }
        assertEquals(selection.server, manager.selected())
        assertEquals(1, storage.writes)

        manager.disconnect()
        assertNull(manager.selected())
    }

    @Test
    fun viewerCannotStartInspectOrRemoveASavedConnection() = runBlocking {
        owner = null
        val existing = SavedPlexServer("Home", "home", endpoint, device.toString(), "server-token")
        storage.saved = existing
        val manager = manager()
        reject { manager.start() }
        reject { manager.selected() }
        reject { manager.disconnect() }
        assertEquals(0, requests)
        assertEquals(0, storage.reads + storage.writes)
        assertEquals(existing, storage.saved)
    }

    @Test
    fun expiryAndOwnerReplacementPreventUsingAStalePin() = runBlocking {
        val manager = manager()
        manager.start()
        time = 10_000
        reject { manager.poll() }
        assertEquals(1, requests)

        manager.start()
        owner = UUID.randomUUID()
        reject { manager.poll() }
        assertEquals(2, requests)
        assertEquals(0, storage.writes)
    }

    @Test
    fun ownerLossDuringServerVerificationPreventsPersistence() = runBlocking {
        val manager = manager(onVerify = { owner = null })
        manager.start()
        linked = true
        val choice = (manager.poll() as PlexConnectionManager.LinkStatus.ChooseServer).servers.single()
        reject { manager.select(choice.id, endpoint) }
        assertNull(storage.saved)
        assertEquals(0, storage.writes)
    }

    private fun manager(onVerify: () -> Unit = {}): PlexConnectionManager {
        val account = PlexAccountClient(device) { request, _ ->
            requests++
            when (request.url.encodedPath) {
                "/api/v2/pins" -> response("""{"id":1,"code":"ABCD","expiresIn":10}""")
                "/api/v2/pins/1" -> response(if (linked) """{"authToken":"account-token"}""" else "{}")
                "/api/v2/resources" -> response(
                    """[{"name":"Home","clientIdentifier":"home","provides":"server","accessToken":"server-token",
                        "connections":[{"uri":"$endpoint","local":true,"relay":false},
                                       {"uri":"http://fixture.example:32400","local":true,"relay":false}]}]""",
                )
                else -> error("Unexpected account request")
            }
        }
        return PlexConnectionManager({ owner }, storage, device, account, { time }) { server, connection ->
            PlexMediaClient(server, connection, device) { request, _ ->
                assertEquals(endpoint + "/library/sections", request.url.toString())
                assertEquals("server-token", request.header("X-Plex-Token"))
                onVerify()
                response("""{"MediaContainer":{"Directory":[{"key":"1","title":"Movies","type":"movie"}]}}""")
            }
        }
    }

    private suspend fun reject(block: suspend () -> Unit) {
        try {
            block()
            fail("Expected the Plex action to be denied.")
        } catch (_: PlexException) {
        }
    }

    private fun response(body: String) = PlexResponse(200, body.toByteArray(), Headers.Builder().build())

    private class MemoryStorage : PlexConnectionStorage {
        var saved: SavedPlexServer? = null
        var reads = 0
        var writes = 0
        override fun read(): SavedPlexServer? = saved.also { reads++ }
        override fun save(server: SavedPlexServer) {
            saved = server
            writes++
        }
        override fun clear() {
            saved = null
            writes++
        }
    }

    private companion object {
        const val endpoint = "https://fixture.example:32400"
    }
}
