package com.dineshdevkota.cinevault.nfs

import com.dineshdevkota.cinevault.smb.NasEntry
import java.io.EOFException
import java.io.IOException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeNotNull
import org.junit.Test

class NfsScopedExportTest {
    @Test
    fun selectedFolderAndIgnoreRulesAreLiteral() = runBlocking {
        val requests = mutableListOf<String>()
        val scope = NfsScopedExport("Films", listOf("Extras"), listOf("Hidden.mp4"), {}, { path ->
            requests += path
            listOf(
                NfsDirectoryEntry("Movie.mp4", false, 6),
                NfsDirectoryEntry("Extras", true, 0),
                NfsDirectoryEntry("extras", true, 0),
                NfsDirectoryEntry("Hidden.mp4", false, 6),
                NfsDirectoryEntry("hidden.mp4", false, 6),
                NfsDirectoryEntry("alias/sibling", true, 0),
            )
        }, { _, _, _ -> error("A denied call must never reach the native reader.") })

        assertEquals(
            listOf(NasEntry("Movie.mp4", false), NasEntry("extras", true), NasEntry("hidden.mp4", false)),
            scope.list("Films"),
        )
        for (path in listOf("", "films", "Films2", "Films/Extras", "Films/../Elsewhere", "Films//Child", "Films\\Child")) {
            assertTrue(path, runCatching { scope.list(path) }.exceptionOrNull() is SecurityException)
        }
        for (path in listOf("Films", "Films/Hidden.mp4", "Films/Extras/Bonus.mp4", "Films2/Movie.mp4")) {
            assertTrue(path, runCatching { scope.open(path) }.exceptionOrNull() is SecurityException)
        }
        assertEquals(listOf("Films"), requests)
    }

    @Test
    fun openAndSeekUseExactNamesAndNeverServeCachedBytesAfterLock() {
        val media = "abcdef".encodeToByteArray()
        val path = "Films/Movie.mp4"
        val reads = mutableListOf<Pair<Long, Int>>()
        var unlocked = true
        val scope = NfsScopedExport("Films", emptyList(), emptyList(), { requested ->
            assertEquals(path, requested)
            if (!unlocked) throw SecurityException("Viewer locked.")
        }, {
            listOf(NfsDirectoryEntry("Movie.mp4", false, media.size.toLong()))
        }, { requested, offset, length ->
            assertEquals(path, requested)
            reads += offset to length
            media.copyOfRange(offset.toInt(), offset.toInt() + length)
        })

        scope.open(path).use { handle ->
            assertEquals(6L, handle.length)
            handle.stream(3L).use { stream ->
                val target = ByteArray(3)
                assertEquals(2, stream.read(target, 1, 2))
                assertArrayEquals(byteArrayOf(0, 'd'.code.toByte(), 'e'.code.toByte()), target)
                unlocked = false
                assertTrue(runCatching { stream.read() }.exceptionOrNull() is SecurityException)
                assertTrue(runCatching { handle.stream(0) }.exceptionOrNull() is SecurityException)
                assertEquals(listOf(3L to 2), reads)
            }
            unlocked = true
            handle.stream(1L).use { assertEquals('b'.code, it.read()) }
        }
        assertEquals(listOf(3L to 2, 1L to 1), reads)
    }

    @Test
    fun sourceChangeAndShortReadLeaveTheCallerBufferUntouched() {
        val path = "Films/Movie.mp4"
        var generation = 1
        var changeDuringRead = true
        val scope = NfsScopedExport("Films", emptyList(), emptyList(), {
            if (generation != 1) throw SecurityException("Source changed.")
        }, {
            listOf(NfsDirectoryEntry("Movie.mp4", false, 6))
        }, { _, _, count ->
            if (changeDuringRead) {
                generation += 1
                ByteArray(count) { 99 }
            } else ByteArray(count - 1) { 88 }
        })
        scope.open(path).use { handle ->
            handle.stream(0).use { stream ->
                val buffer = ByteArray(6) { 9 }
                assertTrue(runCatching { stream.read(buffer) }.exceptionOrNull() is SecurityException)
                assertArrayEquals(ByteArray(6) { 9 }, buffer)
                generation = 1
                changeDuringRead = false
                assertTrue(runCatching { stream.read(buffer) }.exceptionOrNull() is EOFException)
                assertArrayEquals(ByteArray(6) { 9 }, buffer)
            }
        }
    }

    @Test
    fun openRejectsWrongCaseAndAmbiguousOrMissingNativeMetadata() {
        var entries = listOf(NfsDirectoryEntry("Movie.mp4", false, 6))
        val scope = NfsScopedExport("Films", emptyList(), emptyList(), {}, { entries },
            { _, _, _ -> error("An unresolved file must never be read.") })
        assertTrue(runCatching { scope.open("Films/movie.mp4") }.exceptionOrNull() is IOException)
        entries += NfsDirectoryEntry("Movie.mp4", true, 0)
        assertTrue(runCatching { scope.open("Films/Movie.mp4") }.exceptionOrNull() is IOException)
        entries = emptyList()
        assertTrue(runCatching { scope.open("Films/Movie.mp4") }.exceptionOrNull() is IOException)
    }

    @Test
    fun listingHidesDeniedNamesAndLookupRejectsDifferentlyCasedNestedAliases() = runBlocking {
        val requests = mutableListOf<String>()
        val scope = NfsScopedExport("Films", listOf("Private"), emptyList(), { path ->
            if (path == "Films/Restricted.mp4") throw SecurityException("Restricted title.")
        }, { path ->
            requests += path
            when (path) {
                "Films" -> listOf(NfsDirectoryEntry("Private", true, 0), NfsDirectoryEntry("Action", true, 0),
                    NfsDirectoryEntry("Restricted.mp4", false, 6))
                "Films/Action" -> listOf(NfsDirectoryEntry("Movie.mp4", false, 6))
                else -> error("A noncanonical directory must never reach the native reader.")
            }
        }, { _, _, _ -> error("Browsing must not read media.") })

        assertEquals(listOf(NasEntry("Action", true)), scope.list("Films"))
        assertTrue(runCatching { scope.list("Films/private") }.exceptionOrNull() is IOException)
        assertTrue(runCatching { scope.open("Films/action/Movie.mp4") }.exceptionOrNull() is IOException)
        assertEquals(listOf(NasEntry("Movie.mp4", false)), scope.list("Films/Action"))
        assertEquals(listOf("Films", "Films", "Films", "Films", "Films/Action"), requests)
    }

    @Test
    fun loopbackNativeSessionEnforcesSelectedFolderAndRevokesAnOpenStream() = runBlocking {
        val fixturePort = System.getenv("MEDIAVAULT_NFS_LOOPBACK_PORT")
        assumeNotNull(fixturePort)
        val port = requireNotNull(fixturePort).toInt()
        val session = NfsSession.connect("127.0.0.1", "/media", mountPort = port, nfsPort = port)
        try {
            var unlocked = true
            val scope = session.scope("Photos") {
                if (!unlocked) throw SecurityException("Viewer locked.")
            }
            assertEquals(listOf(NasEntry("photo.jpg", false)), scope.list("Photos"))
            assertTrue(runCatching { scope.open("Movie.mp4") }.exceptionOrNull() is SecurityException)
            assertTrue(runCatching { scope.open("Photos/Photo.jpg") }.exceptionOrNull() is IOException)
            scope.open("Photos/photo.jpg").use { handle ->
                assertEquals(12L, handle.length)
                handle.stream(7).use { stream ->
                    val exact = ByteArray(5)
                    assertEquals(5, stream.read(exact))
                    assertArrayEquals("photo".encodeToByteArray(), exact)
                    unlocked = false
                    assertTrue(runCatching { stream.read() }.exceptionOrNull() is SecurityException)
                }
            }
        } finally {
            session.disconnect()
        }
    }
}
