package com.dineshdevkota.cinevault.nfs

import com.dineshdevkota.cinevault.BuildConfig
import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.family.FamilySession
import com.dineshdevkota.cinevault.family.FolderAccess
import com.dineshdevkota.cinevault.family.HouseholdProfile
import com.dineshdevkota.cinevault.smb.NasBrowser
import com.dineshdevkota.cinevault.smb.SmbException
import com.dineshdevkota.cinevault.smb.SmbService
import com.dineshdevkota.cinevault.smb.SourceConfig
import java.io.DataInputStream
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeNotNull
import org.junit.Test

class NfsMediaTest {
    @Test
    fun ordinaryBuildRejectsPersistedNfsWithoutFallingBackToSmb() = runBlocking {
        val source = fixtureSource()
        if (!BuildConfig.NFS_DEVELOPMENT_ENABLED) assertFalse(NfsDevelopment.available)
        assertTrue(source.caseSensitivePaths)
        val service = SmbService()
        var emittedProgress = false
        val rejected = runCatching { service.scanMedia(source) { emittedProgress = true } }.exceptionOrNull()
        assertTrue(rejected is SmbException)
        assertEquals("This source is unavailable.", rejected?.message)
        assertFalse(emittedProgress)
        assertFalse(service.hasPlayableContent(source, "Library/Movie.mp4"))
        assertTrue(runCatching { NasBrowser().listEntries(source) }.exceptionOrNull() is SmbException)
    }

    @Test
    fun injectedServiceScansAndSeeksNativeFixtureWithSessionChecks() = runBlocking {
        val fixturePort = System.getenv("MEDIAVAULT_NFS_MEDIA_LOOPBACK_PORT")?.toIntOrNull()
        assumeNotNull(fixturePort)
        val port = requireNotNull(fixturePort)
        val source = fixtureSource()
        val video = "Library/Movie.mp4"
        var currentSource: SourceConfig? = source
        var viewer = NfsViewer(FamilySession(), 0)
        var movie = MovieEntity(
            sourceId = source.id, filePath = video, fileName = "Movie.mp4", fileSize = 120_000,
            parsedTitle = "Movie", parsedYear = null, title = "Movie", year = null, ageCertification = "PG",
        )
        val access = NfsStoredAccess({ true }, { viewer }, { currentSource }, { _, path ->
            listOf(movie).filter { it.filePath == path }
        })
        val adapter = NfsMedia(authorize = access::authorize,
            mount = { NfsSession.connect(it.host, it.share, mountPort = port, nfsPort = port) })
        val service = SmbService(fileSources = mapOf(NFS to adapter))

        val listed = service.listEntries(source)
        assertEquals(setOf("Movie.mp4", "Movie.en.srt", "movie.en.srt", "Photos"), listed.map { it.name }.toSet())
        assertEquals(listOf("01.jpg"), adapter.browse(source, "Library/Photos").map { it.name })
        assertTrue(runCatching { adapter.browse(source, "Library/photos") }.isFailure)

        val found = service.scanMedia(source) {}
        assertEquals(setOf(video, "Library/Photos/01.jpg"), found.map { it.path }.toSet())
        assertTrue(found.single { it.path == video }.size > 100_000)
        val sidecars = service.readSubtitleSidecars(source, video, preferredLanguage = "en")
        val caption = sidecars.files.single()
        assertEquals("Library/Movie.en.srt", caption.match.path)
        assertTrue(caption.bytes.decodeToString().contains("NFS fixture caption."))

        service.open(source, "Library/Photos/01.jpg").use { handle ->
            handle.stream(0).use { bytes ->
                assertEquals(0xff, bytes.read())
                assertEquals(0xd8, bytes.read())
            }
        }
        service.open(source, video).use { handle ->
            val header = ByteArray(4)
            DataInputStream(handle.stream(4)).use { it.readFully(header) }
            assertArrayEquals("ftyp".encodeToByteArray(), header)

            handle.stream(8).use { stream ->
                viewer = viewer.copy(authenticationEpoch = 1)
                assertTrue(runCatching { stream.read() }.exceptionOrNull() is SecurityException)
            }
        }

        var profile = HouseholdProfile("viewer", "Viewer", movieLimit = "PG")
        viewer = NfsViewer(FamilySession(enabled = true, profile = profile), 1)
        fun denyMovie() = assertTrue(runCatching { service.open(source, video) }.exceptionOrNull() is SecurityException)
        denyMovie()
        profile = profile.copy(folders = listOf(FolderAccess(source.id, "library", caseSensitive = true)))
        viewer = viewer.copy(session = viewer.session.copy(profile = profile))
        denyMovie()
        profile = profile.copy(folders = listOf(FolderAccess(source.id, "Library", caseSensitive = true)))
        viewer = viewer.copy(session = viewer.session.copy(profile = profile))
        movie = movie.copy(ageCertification = "R")
        denyMovie()
        movie = movie.copy(ageCertification = "PG", isHidden = true)
        denyMovie()
        movie = movie.copy(isHidden = false)
        assertTrue(runCatching { service.listEntries(source) }.exceptionOrNull() is SecurityException)
        assertTrue(runCatching { service.open(source, "Library/Photos/01.jpg") }.exceptionOrNull() is SecurityException)
        assertEquals("Library/Movie.en.srt", service.readSubtitleSidecars(source, video).files.single().match.path)
        service.open(source, video).use { handle ->
            handle.stream(8).use { stream ->
                assertTrue(stream.read() >= 0)
                currentSource = source.copy(rootPath = "Library/Photos")
                service.reset(source.id)
                assertTrue(runCatching { stream.read() }.exceptionOrNull() is SecurityException)
            }
        }
        denyMovie()
    }

    @Test
    fun storedArtworkCannotCrossAnExactViewerGrant() = runBlocking {
        val source = fixtureSource()
        val viewer = NfsViewer(FamilySession(enabled = true, profile = HouseholdProfile(
            "viewer", "Viewer", folders = listOf(FolderAccess(source.id, "Library/Kids", caseSensitive = true)),
        )), 1)
        val movie = MovieEntity(
            sourceId = source.id, filePath = "Library/Kids/Movie.mp4", fileName = "Movie.mp4", fileSize = 120_000,
            parsedTitle = "Movie", parsedYear = null, title = "Movie", year = null,
            localPosterPath = "Library/Private/poster.jpg", localBackdropPath = "Library/Kids/backdrop.jpg",
        )
        val access = NfsStoredAccess({ true }, { viewer }, { source }, { _, _ -> listOf(movie) })
        val poster = requireNotNull(movie.localPosterPath)
        assertTrue(runCatching { access.authorize(source, poster, NfsAccessPurpose.FILE) }.exceptionOrNull() is SecurityException)
        val backdrop = requireNotNull(movie.localBackdropPath)
        access.authorize(source, backdrop, NfsAccessPurpose.FILE)(backdrop)
    }

    private fun fixtureSource() = SourceConfig(
        id = "nfs-development-fixture",
        host = "127.0.0.1",
        port = null,
        share = "/media",
        rootPath = "Library",
        username = "",
        password = "",
        sourceType = NFS,
    )
}
