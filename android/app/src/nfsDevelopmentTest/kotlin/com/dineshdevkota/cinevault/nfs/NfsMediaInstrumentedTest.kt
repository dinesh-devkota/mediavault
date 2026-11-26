package com.dineshdevkota.cinevault.nfs

import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.dineshdevkota.cinevault.playback.Media3FixturePlayback
import com.dineshdevkota.cinevault.smb.SmbService
import com.dineshdevkota.cinevault.smb.SourceConfig
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NfsMediaInstrumentedTest {
    @Test
    fun scopedNativeExportScansAndRendersASeekableMovie() = runBlocking {
        val arguments = InstrumentationRegistry.getArguments()
        val host = requireNotNull(arguments.getString("nfsFixtureHost"))
        val port = requireNotNull(arguments.getString("nfsMediaFixturePort")).toInt()
        assertTrue("The opt-in Android NFS libraries must load.", NfsDevelopment.available)
        val config = SourceConfig("nfs-media-fixture", host, null, "/media", "Library", "", "", sourceType = NFS)
        val movie = "Library/Movie.mp4"
        val adapter = NfsMedia(authorize = { source, _, _ ->
            { path ->
                if (source != config || (path != "Library" && !path.startsWith("Library/"))) {
                    throw SecurityException("Outside the synthetic media library.")
                }
            }
        }, mount = { NfsSession.connect(it.host, it.share, mountPort = port, nfsPort = port) })
        val service = SmbService(fileSources = mapOf(NFS to adapter))
        try {
            assertEquals(setOf(movie, "Library/Photos/01.jpg"), service.scanMedia(config) {}.map { it.path }.toSet())
            assertEquals("Library/Movie.en.srt", service.readSubtitleSidecars(config, movie).files.single().match.path)
            Media3FixturePlayback.verify(Uri.parse("nfs://fixture/Movie.mp4")) { service.open(config, movie) }
        } finally {
            service.reset(config.id)
        }
    }
}
