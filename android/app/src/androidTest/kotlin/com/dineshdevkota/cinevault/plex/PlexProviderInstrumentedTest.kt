package com.dineshdevkota.cinevault.plex

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.dineshdevkota.cinevault.data.SecretBox
import java.util.UUID
import kotlinx.coroutines.runBlocking
import okhttp3.Headers
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PlexProviderInstrumentedTest {
    @Test
    fun savesOnlyKeystoreCiphertextAndClearsTheSelectedServer() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val name = "plex-connection-fixture-" + UUID.randomUUID()
        val prefs = context.getSharedPreferences(name, Context.MODE_PRIVATE)
        try {
            val box = SecretBox()
            val store = PlexKeystoreConnectionStore(prefs, box)
            val fakeToken = "plex-fixture-token"
            val server = SavedPlexServer("Home", "id", "https://fixture.example", UUID.randomUUID().toString(), fakeToken)
            store.save(server)
            val sealed = checkNotNull(prefs.getString(PlexKeystoreConnectionStore.KEY, null))
            assertFalse(sealed.contains(fakeToken))
            assertFalse(sealed.contains("fixture.example"))
            assertFalse(prefs.all.values.toString().contains(fakeToken))
            val restored = checkNotNull(PlexKeystoreConnectionStore(prefs, SecretBox()).read())
            assertEquals(fakeToken, restored.serverToken)
            assertEquals(server.endpoint, restored.endpoint)
            assertEquals(server.deviceID, restored.deviceID)
            store.clear()
            assertNull(store.read())
            assertNull(prefs.getString(PlexKeystoreConnectionStore.KEY, null))
        } finally {
            context.deleteSharedPreferences(name)
        }
    }

    @Test
    fun selectedServerCatalogDecodesAndReadsAnExactRange() = runBlocking {
        val connection = PlexAccountClient.Connection("https://fixture.example:32400", local = true, relay = false)
        val server = PlexAccountClient.Server("Demo", "fixture", "server", "server-token", listOf(connection))
        val client = PlexMediaClient(server, connection, UUID.randomUUID()) { request, maximumBytes ->
            assertEquals("fixture.example", request.url.host)
            assertEquals("server-token", request.header("X-Plex-Token"))
            if (request.url.encodedPath.endsWith("/all")) {
                assertEquals(setOf("includeGuids"), request.url.queryParameterNames)
                assertEquals("1", request.url.queryParameter("includeGuids"))
            } else {
                assertNull(request.url.query)
            }
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
