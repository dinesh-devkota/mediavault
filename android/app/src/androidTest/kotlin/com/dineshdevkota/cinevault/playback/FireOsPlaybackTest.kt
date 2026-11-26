@file:OptIn(androidx.media3.common.util.UnstableApi::class)

package com.dineshdevkota.cinevault.playback

import android.content.Intent
import android.os.Build
import android.view.KeyEvent
import android.view.View
import androidx.annotation.OptIn
import androidx.lifecycle.Lifecycle
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.UiDevice
import com.dineshdevkota.cinevault.CineVaultApp
import com.dineshdevkota.cinevault.R
import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.data.SourceEntity
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Real foreground playback, transport keys and decoder release on the API22/25 CI matrix. */
@RunWith(AndroidJUnit4::class)
class FireOsPlaybackTest {
    @Test fun remoteTransportAndLifecycleResumeTheSameNasMovie() = runBlocking<Unit> {
        val app = ApplicationProvider.getApplicationContext<CineVaultApp>()
        val container = app.container
        val host = requireNotNull(InstrumentationRegistry.getArguments().getString("nasHost"))
        assertFalse("Use a disposable fixture installation", container.family.current.enabled)
        val source = SourceEntity(name = "Fire OS playback fixture", host = host, port = 1445, share = "FORMATPLAYBACK",
            username = "cinevault", encryptedPassword = container.secrets.encrypt("fixture-only"))
        val movie = MovieEntity(sourceId = source.id, filePath = "Controls.mkv", fileName = "Controls.mkv", fileSize = 100,
            parsedTitle = "Remote controls", parsedYear = null, title = "Remote controls", year = null)
        try {
            container.database.sources().upsert(source); container.database.movies().insert(movie)
            ActivityScenario.launch<PlayerActivity>(Intent(app, PlayerActivity::class.java).putExtra("movie_id", movie.id)).use { scenario ->
                await(scenario) { player -> player.isPlaying && (player as? ExoPlayer)?.videoDecoderCounters?.renderedOutputBufferCount?.let { it > 0 } == true }
                scenario.onActivity { activity ->
                    // Transport must keep working while the separate header button has focus.
                    assertTrue(activity.findViewById<View>(R.id.playback_subtitles).requestFocus())
                }
                transport(KeyEvent.KEYCODE_MEDIA_PAUSE)
                await(scenario) { !it.playWhenReady }
                transport(KeyEvent.KEYCODE_MEDIA_FAST_FORWARD)
                await(scenario) { it.currentPosition >= 9000 }
                var forwardPosition = 0L
                scenario.onActivity { forwardPosition = it.player()!!.currentPosition }
                transport(KeyEvent.KEYCODE_MEDIA_REWIND)
                await(scenario) { it.currentPosition < forwardPosition }
                scenario.onActivity { it.player()!!.seekTo(20_000) }
                transport(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
                await(scenario) { it.isPlaying && it.currentPosition >= 20_000 }
                // STARTED is paused but still visible. API22 must release its decoder at this point.
                scenario.moveToState(Lifecycle.State.STARTED)
                if (Build.VERSION.SDK_INT < 24) scenario.onActivity { assertNull(it.player()) }
                scenario.moveToState(Lifecycle.State.CREATED)
                container.playbackProgress.await { }
                assertTrue(container.database.movies().get(movie.id)!!.playbackPositionMs >= 20_000)
                scenario.moveToState(Lifecycle.State.RESUMED)
                await(scenario) { it.isPlaying && it.currentPosition >= 20_000 && it.currentMediaItem?.mediaId == movie.id }
            }
        } finally {
            container.playbackProgress.await { }
            container.database.sources().delete(source.id); container.smb.reset(source.id)
        }
    }

    private fun PlayerActivity.player(): Player? = findViewById<PlayerView>(R.id.playback_view)?.player
    private fun transport(key: Int) {
        assertTrue(UiDevice.getInstance(InstrumentationRegistry.getInstrumentation()).pressKeyCode(key))
    }
    private suspend fun await(scenario: ActivityScenario<PlayerActivity>, predicate: (Player) -> Boolean) = withTimeout(30_000) {
        var ready = false
        while (!ready) {
            scenario.onActivity { activity -> activity.player()?.let { player ->
                player.playerError?.let { throw AssertionError("Fixture playback failed: ${it.errorCodeName}", it) }
                ready = predicate(player)
            } }
            if (!ready) delay(100)
        }
    }
}
