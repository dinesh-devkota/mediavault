package com.dineshdevkota.cinevault.nfs

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.IOException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NfsProviderInstrumentedTest {
    @Test
    fun mountedExportListsAndReadsNestedFiles() = runBlocking {
        val session = connect()
        try {
            val rootEntries = session.list().associateBy { it.name }
            assertEquals(setOf("Movie.mp4", "Photos", "truncated.mp4"), rootEntries.keys)
            assertEquals(NfsDirectoryEntry("Movie.mp4", false, 19), rootEntries["Movie.mp4"])
            assertEquals(NfsDirectoryEntry("Photos", true, 0), rootEntries["Photos"])
            assertEquals(listOf(NfsDirectoryEntry("photo.jpg", false, 12)), session.list("Photos"))
            assertArrayEquals("photo".encodeToByteArray(), session.read("Photos/photo.jpg", 7, 5))
        } finally {
            session.disconnect()
        }
        session.disconnect()
        try {
            session.list()
            fail("Disconnected NFS session should reject reads.")
        } catch (_: IllegalStateException) {
        }
    }

    @Test
    fun refusesTraversalSymlinksCaseChangesAndShortResponses() = runBlocking {
        val session = connect()
        try {
            expectsFailure { session.list("PhotoAlias") }
            expectsFailure { session.read("PhotoAlias/photo.jpg", 0, 1) }
            expectsFailure { session.read("link.mp4", 0, 1) }
            expectsFailure { session.read("../Movie.mp4", 0, 1) }
            expectsFailure { session.read("movie.mp4", 0, 1) }
            expectsFailure { session.read("Movie.mp4", Long.MAX_VALUE, 1) }
            expectsFailure { session.read("truncated.mp4", 0, 12) }
        } finally {
            session.disconnect()
        }
    }

    private suspend fun connect(): NfsSession {
        val arguments = InstrumentationRegistry.getArguments()
        val host = requireNotNull(arguments.getString("nfsFixtureHost"))
        val port = requireNotNull(arguments.getString("nfsFixturePort")).toInt()
        return NfsSession.connect(host, "/media", mountPort = port, nfsPort = port)
    }

    private suspend fun expectsFailure(operation: suspend () -> Unit) {
        try {
            operation()
            fail("This NFS operation should have been rejected.")
        } catch (_: IOException) {
        }
    }
}
