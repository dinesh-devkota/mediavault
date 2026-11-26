package com.dineshdevkota.cinevault.plex

import java.util.UUID
import kotlinx.coroutines.runBlocking
import okhttp3.Headers
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Test

class PlexClientTest {
    private val device = UUID.fromString("388619aa-451b-4ef5-8f08-990485839914")

    @Test
    fun pinAndServerDiscoveryKeepAccountTokenOnPlex() = runBlocking {
        val client = PlexAccountClient(device) { request, _ ->
            assertEquals("plex.tv", request.url.host)
            assertEquals(device.toString(), request.header("X-Plex-Client-Identifier"))
            assertFalse(request.url.toString().contains("account-token"))
            when (request.url.encodedPath) {
                "/api/v2/pins" -> {
                    assertEquals("POST", request.method)
                    assertEquals("false", request.url.queryParameter("strong"))
                    assertNull(request.header("X-Plex-Token"))
                    reply("""{"id":14,"code":"ABCD","expiresIn":45}""", 201)
                }
                "/api/v2/pins/14" -> {
                    assertEquals("GET", request.method)
                    assertEquals("ABCD", request.url.queryParameter("code"))
                    assertNull(request.header("X-Plex-Token"))
                    reply("""{"authToken":"account-token"}""")
                }
                "/api/v2/resources" -> {
                    assertEquals("account-token", request.header("X-Plex-Token"))
                    reply(
                        """
                        [{"name":"Demo","clientIdentifier":"fixture","provides":"server","accessToken":"server-token",
                          "connections":[{"uri":"https://fixture.example:32400","local":true,"relay":false},
                                         {"uri":"http://fixture.example:32400","local":true,"relay":false}]},
                         {"name":"Player","clientIdentifier":"player","provides":"player","connections":[]}]
                        """.trimIndent(),
                    )
                }
                else -> error("Unexpected Plex account request")
            }
        }
        val token = requireNotNull(client.pollLink(client.beginLink()))
        val server = client.servers(token).single()
        assertEquals("Demo", server.name)
        assertEquals("https://fixture.example:32400", server.secureConnections.single().uri)
    }

    @Test
    fun catalogPaginatesAndReadsSelectedServerRanges() = runBlocking {
        val client = mediaClient { request, limit ->
            assertEquals("fixture.example", request.url.host)
            assertEquals(32400, request.url.port)
            assertEquals("server-token", request.header("X-Plex-Token"))
            if (request.url.encodedPath.endsWith("/all")) {
                assertEquals(setOf("includeGuids"), request.url.queryParameterNames)
                assertEquals("1", request.url.queryParameter("includeGuids"))
            } else {
                assertNull(request.url.query)
            }
            when (request.url.encodedPath) {
                "/library/sections" -> reply(
                    """{"MediaContainer":{"Directory":[{"key":"1","title":"Movies","type":"movie"}]}}""",
                )
                "/library/sections/1/all" -> when (request.header("X-Plex-Container-Start")) {
                    "0" -> reply(
                        """
                            {"MediaContainer":{"size":1,"totalSize":2,"offset":0,"Metadata":[
                              {"ratingKey":"7","type":"movie","title":"First","Media":[
                                {"Part":[{"key":"/library/parts/9/1500/file.mp4","size":10,"container":"mp4"}]},
                                {"Part":[{"key":"https://other.example/library/parts/1/file.mp4","size":10}]},
                                {"Part":[{"key":"/library/parts/1/../file.mp4","size":10}]}
                              ]}
                            ]}}
                        """.trimIndent(),
                    )
                    "1" -> reply(
                        """{"MediaContainer":{"size":1,"totalSize":2,"offset":1,"Metadata":[{"ratingKey":"8","type":"movie","title":"Second"}]}}""",
                    )
                    else -> error("Unexpected page offset")
                }
                "/library/parts/9/1500/file.mp4" -> {
                    assertEquals(5, limit)
                    assertEquals("bytes=5-9", request.header("Range"))
                    reply("56789", 206, "bytes 5-9/10")
                }
                else -> error("Unexpected Plex media request")
            }
        }

        val items = mutableListOf<PlexMediaClient.Item>()
        client.catalog(client.libraries().single()) { items += it }
        assertEquals(listOf("First", "Second"), items.map { it.title })
        val part = client.singleFileParts(items.first()).single()
        assertArrayEquals("56789".toByteArray(), client.read(part, offset = 5, length = 5))

        val otherClient = mediaClient { _, _ -> error("A part from a different client must never produce a request") }
        try {
            otherClient.read(part, offset = 5, length = 5)
            fail("Expected server binding to reject this media part")
        } catch (_: PlexException) {
        }
    }

    @Test
    fun currentItemMustStillBelongToTheLinkedLibrary() = runBlocking {
        val client = mediaClient { request, _ ->
            assertEquals("/library/metadata/7", request.url.encodedPath)
            reply("""{"MediaContainer":{"librarySectionID":1,"Metadata":[
                {"ratingKey":"7","type":"movie","title":"Film","librarySectionID":"1"}]}}""")
        }
        assertEquals("Film", client.item("7", "1").title)
        try {
            client.item("7", "2")
            fail("Expected the wrong library to be rejected")
        } catch (_: PlexException) {
        }
    }

    private fun mediaClient(exchange: PlexExchange): PlexMediaClient {
        val connection = PlexAccountClient.Connection("https://fixture.example:32400", local = true, relay = false)
        val server = PlexAccountClient.Server("Demo", "fixture", "server", "server-token", listOf(connection))
        return PlexMediaClient(server, connection, device, exchange)
    }

    private fun reply(body: String, status: Int = 200, range: String? = null): PlexResponse {
        val headers = Headers.Builder()
        if (range != null) headers.add("Content-Range", range)
        return PlexResponse(status, body.toByteArray(), headers.build())
    }
}
