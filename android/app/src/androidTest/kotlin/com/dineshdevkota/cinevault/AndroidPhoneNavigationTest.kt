@file:OptIn(androidx.media3.common.util.UnstableApi::class)

package com.dineshdevkota.cinevault

import android.content.Intent
import android.os.SystemClock
import android.view.View
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.click
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasScrollToIndexAction
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isEnabled
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.performTouchInput
import androidx.media3.ui.PlayerView
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import androidx.test.uiautomator.UiDevice
import com.dineshdevkota.cinevault.playback.PlayerActivity
import com.dineshdevkota.cinevault.ui.isTelevision
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidPhoneNavigationTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val application = ApplicationProvider.getApplicationContext<CineVaultApp>()
    private val device = UiDevice.getInstance(instrumentation)

    @Test
    fun handheldLauncherOpensSourceFormAndShowsAddressValidation() {
        launchPhone().use {
            openSetup()
            tap("Connect", scroll = true)
            visible(hasText("Enter a NAS address or select a device."), scroll = true)
            visible(hasText("NAS address") and hasSetTextAction(), scroll = true)
        }
    }

    @Test
    fun touchSetupImportsMovieAndPlaysAndSeeksWithNativeControls() {
        val container = application.container
        val host = InstrumentationRegistry.getArguments().getString("nasHost")
        assertEquals("The test requires the disposable runner's local NAS", "10.0.2.2", host)
        runBlocking { assertTrue("Prepare an empty disposable library", container.database.sources().observeAll().first().isEmpty()) }
        launchPhone().use {
            openSetup()
            fill("NAS address", "smb://$host:1445")
            tap("Sign in", scroll = true)
            fill("Username", "cinevault")
            fill("Password", "fixture-only")
            tap("Connect", scroll = true)
            tap("CINEVAULT", scroll = true)
            tap("Movies", scroll = true)
            tap("Feature (2020)", scroll = true)
            visible(hasText("No subfolders. You can use this folder."), scroll = true)
            tap("Use this folder & scan", scroll = true)

            // The selected title comes from this run's folder scan and real SMB fixture.
            runBlocking {
                withTimeout(60_000) {
                    while (container.database.sources().observeAll().first().singleOrNull()?.lastScanAt == null) delay(100)
                    val source = container.database.sources().observeAll().first().single()
                    assertEquals("Movies/Feature (2020)", source.rootPath)
                    assertEquals("Movies/Feature (2020)/Feature (2020).mp4", container.database.movies().forSource(source.id).single().filePath)
                }
            }
            tap("Library")
            tap("Feature", scroll = true)
            tap("Play")
            awaitPlayerState("the movie should decode and play on the phone") { view ->
                val player = view.player
                player != null && player.isPlaying && player.videoSize.width > 0 &&
                    player.currentPosition >= 250 && player.isCurrentMediaItemSeekable
            }

            withPlayerView { view -> view.takeIf { !it.isControllerFullyVisible }?.point(0.5f) }?.let { point ->
                assertTrue("Tap the player to reveal playback controls", device.click(point.first, point.second))
            }
            lateinit var seekPoint: Pair<Int, Int>
            awaitPlayerState("the native seek bar should be accessible by touch") { view ->
                val bar = view.findViewById<View>(androidx.media3.ui.R.id.exo_progress)
                if (bar == null || !bar.isShown || bar.width == 0) false
                else { seekPoint = bar.point(0.68f); true }
            }
            assertTrue("Tap the native seek bar", device.click(seekPoint.first, seekPoint.second))
            awaitPlayerState("touch seek should advance playback inside the 12-second fixture") { view ->
                val player = view.player
                player != null && player.isPlaying && player.currentPosition in 7_500L..11_000L
            }
            device.pressBack()
            visible(hasText("Feature") and !hasClickAction())
        }
    }

    private fun launchPhone(): ActivityScenario<MainActivity> {
        assertEquals("Only run this test on a disposable phone emulator", "true", InstrumentationRegistry.getArguments().getString("phoneUiFixture"))
        assertFalse("This test expects a phone UI", application.resources.configuration.isTelevision())
        val launcher = checkNotNull(application.packageManager.getLaunchIntentForPackage(application.packageName))
        assertTrue(launcher.hasCategory(Intent.CATEGORY_LAUNCHER))
        return ActivityScenario.launch(launcher)
    }

    private fun openSetup() {
        tap("Sources")
        tap("Add NAS Source")
        tap("Enter NAS address", scroll = true)
    }

    private fun tap(text: String, scroll: Boolean = false) {
        visible(hasText(text) and hasClickAction() and isEnabled(), scroll).performTouchInput { click() }
    }

    private fun fill(label: String, value: String) {
        val matcher = hasText(label) and hasSetTextAction()
        visible(matcher, scroll = true).performTouchInput { click() }
        visible(matcher, scroll = true).performTextReplacement(value)
    }

    private fun visible(matcher: SemanticsMatcher, scroll: Boolean = false): SemanticsNodeInteraction {
        val node = compose.onNode(matcher)
        compose.waitUntil(timeoutMillis = 30_000) {
            try {
                if (scroll) compose.onAllNodes(hasScrollToIndexAction()).onFirst().performScrollToNode(matcher)
                node.assertIsDisplayed()
                true
            } catch (_: AssertionError) { false }
        }
        return node
    }

    private fun awaitPlayerState(description: String, matches: (PlayerView) -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 30_000
        while (SystemClock.elapsedRealtime() < deadline) {
            if (withPlayerView(matches) == true) return
            SystemClock.sleep(80)
        }
        error(description)
    }

    private fun <T> withPlayerView(read: (PlayerView) -> T): T? {
        var result: T? = null
        instrumentation.runOnMainSync {
            val player = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED)
                .filterIsInstance<PlayerActivity>().singleOrNull()
            player?.findViewById<PlayerView>(R.id.playback_view)?.let { result = read(it) }
        }
        return result
    }

    private fun View.point(horizontalFraction: Float): Pair<Int, Int> {
        val location = IntArray(2)
        getLocationOnScreen(location)
        return (location[0] + (width * horizontalFraction).toInt()) to (location[1] + height / 2)
    }
}
