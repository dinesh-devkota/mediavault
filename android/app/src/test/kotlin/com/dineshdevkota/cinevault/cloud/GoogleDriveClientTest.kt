package com.dineshdevkota.cinevault.cloud

import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class GoogleDriveClientTest {
    @Test
    fun catalogUsesDriveIdentifiersAndPreservesResourceKeys() = runBlocking {
        val client = GoogleDriveClient(OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request()
            assertEquals("www.googleapis.com", request.url.host)
            assertEquals("Bearer fixture", request.header("Authorization"))
            assertEquals("folder/key", request.header("X-Goog-Drive-Resource-Keys"))
            assertEquals("'folder' in parents and trashed = false", request.url.queryParameter("q"))
            assertEquals("true", request.url.queryParameter("includeItemsFromAllDrives"))
            val body = when (request.url.queryParameter("pageToken")) {
                null -> """{"files":[],"nextPageToken":"next+page"}"""
                "next+page" -> """{"files":[{"id":"media","name":"Film.mp4","mimeType":"video/mp4","resourceKey":"filmKey"}]}"""
                else -> error("Unexpected page token")
            }
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("Fixture")
                .body(body.toResponseBody()).build()
        }.build())
        val entries = mutableListOf<GoogleDriveClient.Entry>()
        client.listChildren("folder", "fixture", "key") { entries.addAll(it) }
        assertEquals(listOf("media"), entries.map { it.id })
        assertEquals("filmKey", entries.single().resourceKey)
    }

    @Test
    fun acceptsOnlyAnExactBoundedMediaRange() {
        val client = GoogleDriveClient(OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request()
            assertEquals("/drive/v3/files/id", request.url.encodedPath)
            assertEquals("media", request.url.queryParameter("alt"))
            assertEquals("true", request.url.queryParameter("supportsAllDrives"))
            assertEquals("identity", request.header("Accept-Encoding"))
            val requestRange = request.header("Range") ?: error("Missing range")
            val (status, returnedRange, body) = when (requestRange) {
                "bytes=5-9" -> Triple(206, "bytes 5-9/10", "56789")
                "bytes=1-5" -> Triple(206, "bytes 1-5/10/20", "12345")
                "bytes=2-6" -> Triple(206, "bytes 2-6/10", "23")
                "bytes=3-7" -> Triple(200, "bytes 3-7/10", "0123456789")
                else -> error("Unexpected range")
            }
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(status).message("Fixture")
                .header("Content-Range", returnedRange).body(body.toResponseBody()).build()
        }.build())
        val data = runBlocking { client.read("id", 5, 5, "fixture") }
        assertArrayEquals("56789".toByteArray(), data)
        for (offset in 1L..3L) {
            assertThrows(CloudClientException::class.java) { runBlocking { client.read("id", offset, 5, "fixture") } }
        }
        assertThrows(IllegalArgumentException::class.java) { runBlocking { client.read("../id", 0, 1, "fixture") } }
    }
}
