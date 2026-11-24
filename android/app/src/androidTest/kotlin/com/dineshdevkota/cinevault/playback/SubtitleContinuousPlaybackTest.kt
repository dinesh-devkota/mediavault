@file:OptIn(UnstableApi::class)

package com.dineshdevkota.cinevault.playback

import android.content.Intent
import android.view.View
import android.view.ViewGroup
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.PlayerView
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import com.dineshdevkota.cinevault.CineVaultApp
import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.data.SourceEntity
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Uses only the dedicated, synthetic MEDIAPLAYBACK share and a disposable empty app library. */
@RunWith(AndroidJUnit4::class)
class SubtitleContinuousPlaybackTest {
    private val app = ApplicationProvider.getApplicationContext<CineVaultApp>()
    private val container get() = app.container
    private val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
    private var source: SourceEntity? = null
    private var oldContinuous = false
    private var oldAutomatic = false
    private var oldLanguage = "en"
    private var oldPreference: String? = null
    private lateinit var episodes: List<MovieEntity>

    @Before fun prepare() = runBlocking<Unit> {
        val host = InstrumentationRegistry.getArguments().getString("nasHost")
        assumeTrue("Pass nasHost to run synthetic subtitle playback", !host.isNullOrBlank())
        assumeTrue("Use a disposable empty test library", container.database.sources().all().isEmpty())
        oldContinuous = container.settings.continuousPlay
        oldAutomatic = container.settings.automaticSubtitles
        oldLanguage = container.settings.subtitleLanguage
        oldPreference = container.settings.subtitlePreference
        container.settings.continuousPlay = true
        container.settings.automaticSubtitles = false
        container.settings.subtitleLanguage = "en"
        container.settings.subtitlePreference = "en"
        val nas = SourceEntity(name = "Synthetic playback", host = host!!, port = 1445, share = "MEDIAPLAYBACK",
            rootPath = "TV Shows", username = "cinevault", encryptedPassword = container.secrets.encrypt("fixture-only"))
        source = nas
        container.database.sources().upsert(nas)
        episodes = listOf(1, 2, 4).map { number ->
            val name = "Fixture Show.S01E${number.toString().padStart(2, '0')}.mp4"
            MovieEntity(sourceId = nas.id, filePath = "TV Shows/Fixture Show/Season 01/$name", fileName = name,
                fileSize = 100, parsedTitle = "Fixture Show", parsedYear = null, title = "Fixture episode $number", year = null,
                seriesTitle = "Fixture Show", seasonNumber = 1, episodeNumber = number)
        }
        episodes.forEach { container.database.movies().insert(it) }
    }

    @After fun cleanUp() = runBlocking<Unit> {
        val nas = source ?: return@runBlocking
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            Stage.entries.flatMap { ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(it) }
                .filterIsInstance<PlayerActivity>().toSet().forEach { it.finish() }
        }
        container.playbackProgress.await { }
        container.database.sources().delete(nas.id)
        container.smb.reset(nas.id)
        container.settings.continuousPlay = oldContinuous
        container.settings.automaticSubtitles = oldAutomatic
        container.settings.subtitlePreference = oldPreference
        container.settings.subtitleLanguage = oldLanguage
    }

    @Test fun validSidecarsRenderAndOffSurvivesRecreation() = runBlocking<Unit> {
        container.settings.continuousPlay = false
        launch().use { scenario ->
            awaitPlayer(scenario) { it.isPlaying && it.currentTracks.groups.count { group -> group.type == C.TRACK_TYPE_TEXT } >= 2 }
            scenario.onActivity { activity ->
                val tracks = activity.player()!!.currentTracks.groups.filter { it.type == C.TRACK_TYPE_TEXT }
                assertEquals("Malformed, oversized and another episode's captions must be rejected", 2, tracks.size)
                assertEquals(setOf("en", "es"), tracks.map { it.getTrackFormat(0).language }.toSet())
                assertTrue("Preferred English caption should be selected", tracks.any { it.getTrackFormat(0).language == "en" && it.isSelected })
            }
            // Exercise the actual TV subtitle controls, then recreate like an app lifecycle restart.
            scenario.onActivity { it.playerView()!!.showController() }
            click("Subtitles")
            click("Off")
            assertEquals("off", container.settings.subtitlePreference)
            scenario.recreate()
            awaitPlayer(scenario) { it.isPlaying && it.currentTracks.groups.any { group -> group.type == C.TRACK_TYPE_TEXT } }
            scenario.onActivity { activity ->
                val player = activity.player()!!
                assertTrue(C.TRACK_TYPE_TEXT in player.trackSelectionParameters.disabledTrackTypes)
                assertFalse(player.currentTracks.isTypeSelected(C.TRACK_TYPE_TEXT))
            }
        }
    }

    @Test fun backCancelsCountdownAndNeverLaunchesNextEpisode() = runBlocking<Unit> {
        launch().use { scenario ->
            awaitPlayer(scenario) { it.isPlaying && it.duration > 0 }
            finishVideo(scenario)
            visible("Play now")
            device.pressBack()
            delay(11_000)
            assertNull("Back must cancel pending work, not launch another activity", resumedPlayerId())
            assertNull(container.database.movies().get(episodes[1].id)!!.lastPlayedAt)
        }
    }

    @Test fun playNowRevalidatesAndCarriesOffToNextEpisode() = runBlocking<Unit> {
        container.settings.subtitlePreference = "off"
        launch().use { scenario ->
            awaitPlayer(scenario) { it.isPlaying && it.duration > 0 }
            finishVideo(scenario)
            visible("Next episode · S01E02")
            click("Play now")
            withTimeout(30_000) {
                while (resumedPlayerId() != episodes[1].id) delay(100)
            }
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                val player = resumedActivity()?.player() ?: error("Next player missing")
                assertTrue(C.TRACK_TYPE_TEXT in player.trackSelectionParameters.disabledTrackTypes)
            }
        }
    }

    @Test fun countdownAutomaticallyContinuesOnlyWhilePlayerIsVisible() = runBlocking<Unit> {
        launch().use { scenario ->
            awaitPlayer(scenario) { it.isPlaying && it.duration > 0 }
            finishVideo(scenario)
            visible("Play now")
            withTimeout(30_000) { while (resumedPlayerId() != episodes[1].id) delay(100) }
            assertTrue(container.database.movies().get(episodes[0].id)!!.isWatched)
        }
    }

    @Test fun leavingTheAppCancelsThePendingTransition() = runBlocking<Unit> {
        launch().use { scenario ->
            awaitPlayer(scenario) { it.isPlaying && it.duration > 0 }
            finishVideo(scenario)
            visible("Play now")
            device.pressHome()
            delay(11_000)
            assertNull("No player may open in front of the TV home screen", resumedPlayerId())
            assertNull(container.database.movies().get(episodes[1].id)!!.lastPlayedAt)
        }
    }

    @Test fun hidingTheProposedEpisodeCancelsInsteadOfSilentlyAdvancingElsewhere() = runBlocking<Unit> {
        launch().use { scenario ->
            awaitPlayer(scenario) { it.isPlaying && it.duration > 0 }
            finishVideo(scenario)
            visible("Next episode · S01E02")
            container.database.movies().setHidden(episodes[1].id, true)
            click("Play now")
            withTimeout(10_000) { while (resumedPlayerId() != null) delay(100) }
            assertNull(container.database.movies().get(episodes[2].id)!!.lastPlayedAt)
        }
    }

    private fun launch(): ActivityScenario<PlayerActivity> = ActivityScenario.launch(
        Intent(app, PlayerActivity::class.java).putExtra("movie_id", episodes.first().id).putExtra("resume", false),
    )
    private suspend fun awaitPlayer(scenario: ActivityScenario<PlayerActivity>, predicate: (Player) -> Boolean) {
        withTimeout(45_000) {
            while (true) {
                var ready = false
                scenario.onActivity { activity ->
                    activity.player()?.let { player ->
                        player.playerError?.let { throw AssertionError("Synthetic playback failed", it) }
                        ready = predicate(player)
                    }
                }
                if (ready) return@withTimeout
                delay(100)
            }
        }
    }
    private fun finishVideo(scenario: ActivityScenario<PlayerActivity>) {
        scenario.onActivity { it.player()!!.let { player -> player.seekTo((player.duration - 200).coerceAtLeast(0)); player.play() } }
    }
    private fun visible(text: String) { assertTrue("Expected $text", device.wait(Until.hasObject(By.text(text)), 15_000)) }
    private fun click(text: String) { visible(text); device.findObject(By.text(text)).click(); device.waitForIdle() }
    private fun resumedPlayerId(): String? {
        var id: String? = null
        InstrumentationRegistry.getInstrumentation().runOnMainSync { id = resumedActivity()?.player()?.currentMediaItem?.mediaId }
        return id
    }
    private fun resumedActivity(): PlayerActivity? = ActivityLifecycleMonitorRegistry.getInstance()
        .getActivitiesInStage(Stage.RESUMED).filterIsInstance<PlayerActivity>().firstOrNull()
    private fun PlayerActivity.playerView(): PlayerView? = findPlayer(window.decorView)
    private fun PlayerActivity.player(): Player? = playerView()?.player
    private fun findPlayer(view: View): PlayerView? {
        if (view is PlayerView) return view
        if (view is ViewGroup) for (index in 0 until view.childCount) findPlayer(view.getChildAt(index))?.let { return it }
        return null
    }
}
