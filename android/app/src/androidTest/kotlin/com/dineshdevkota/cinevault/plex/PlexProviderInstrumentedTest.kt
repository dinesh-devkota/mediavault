package com.dineshdevkota.cinevault.plex

import androidx.test.ext.junit.runners.AndroidJUnit4
import java.util.UUID
import kotlinx.coroutines.runBlocking
import okhttp3.Headers
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PlexProviderInstrumentedTest {
    @Test
    fun selectedServerCatalogDecodesAndReadsAnExactRange() = runBlocking {
        val connection = PlexAccountClient.Connection("https://fixture.example:32400", local = true, relay = false)
        val server = PlexAccountClient.Server("Demo", "fixture", "server", "server-token", listOf(connection))
        val client = PlexMediaClient(server, connection, UUID.randomUUID()) { request, maximumBytes ->
            assertEquals("fixture.example", request.url.host)
            assertEquals("server-token", request.header("X-Plex-Token"))
            assertNull(request.url.query)
            when (request.url.encodedPath) {
                "/library/sections" -> PlexResponse(
                    200,
                    """{"MediaContainer":{"Directory":[{"key":"1","title":"Movies","type":"movie"}]}}""".toByteArray(),
                    Headers.Builder().build(),
                )
                "/library/sections/1/all" -> PlexResponse(
                    200,
                    """
                    {"MediaContainer":{"size":1,"totalSize":1,"Metadata":[{"ratingKey":"7","type":"movie","title":"Demo",
                      "Media":[{"Part":[{"key":"/library/parts/9/file.mp4","size":10,"container":"mp4"}]}]}]}}
                    """.trimIndent().toByteArray(),
                    Headers.Builder().build(),
                )
                "/library/parts/9/file.mp4" -> {
                    assertEquals("bytes=5-9", request.header("Range"))
                    assertEquals(5, maximumBytes)
                    PlexResponse(206, "56789".toByteArray(), Headers.Builder().add("Content-Range", "bytes 5-9/10").build())
                }
                else -> error("Unexpected Plex request")
            }
        }
        val items = mutableListOf<PlexMediaClient.Item>()
        client.catalog(client.libraries().single()) { items += it }
        assertEquals("Demo", items.single().title)
        val part = client.singleFileParts(items.single()).single()
        assertArrayEquals("56789".toByteArray(), client.read(part, offset = 5, length = 5))
    }
}
