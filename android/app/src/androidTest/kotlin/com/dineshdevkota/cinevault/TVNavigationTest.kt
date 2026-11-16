package com.dineshdevkota.cinevault

import android.os.Build
import androidx.test.core.app.ApplicationProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.Condition
import androidx.test.uiautomator.UiDevice
import com.dineshdevkota.cinevault.data.MovieEntity
import com.dineshdevkota.cinevault.data.SourceEntity
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayOutputStream

/** Exercises actual remote input and focus on Android TV, without a touchscreen. */
@RunWith(AndroidJUnit4::class)
class TVNavigationTest {
    private val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
    private val focusSnapshots = mutableListOf<String>()
    private var scenario: ActivityScenario<MainActivity>? = null

    @Test
    fun remoteCanReachEveryTabAndReturnHome() {
        ActivityScenario.launch(MainActivity::class.java).use { activity ->
            scenario = activity
            visible("Connect your first shared folder")
            device.pressDPadRight()
            visible("No movies yet")
            device.pressDPadRight()
            visible("Your photos, on the big screen")
            device.pressDPadRight()
            visible("Search your collection")
            device.pressDPadRight()
            visible("No NAS sources yet")
            device.pressDPadRight()
            visible("Metadata (themoviedb.org)")
            device.pressBack()
            visible("Connect your first shared folder")
        }
    }

    @Test
    fun selectedTabAndFocusSurviveActivityRecreation() {
        ActivityScenario.launch(MainActivity::class.java).use { activity ->
            scenario = activity
            visible("Connect your first shared folder")
            repeat(4) { device.pressDPadRight() }
            visible("No NAS sources yet")
            activity.recreate()
            visible("No NAS sources yet")
            device.pressDPadRight()
            visible("Metadata (themoviedb.org)")
        }
    }

    @Test
    fun homeActionsFollowVisiblePhotosAndOpenTheCorrectTab() = runBlocking<Unit> {
        val container = ApplicationProvider.getApplicationContext<CineVaultApp>().container
        val database = container.database
        assumeTrue("Use a disposable empty test library", database.sources().all().isEmpty())
        val source = SourceEntity(name = "Home test folder", host = "127.0.0.1", port = 1, share = "media",
            ignoredFolders = listOf("Trips"))
        try {
            ActivityScenario.launch(MainActivity::class.java).use { activity ->
                scenario = activity
                visible("Find my NAS")
                database.sources().upsert(source)
                database.movies().insert(MovieEntity(sourceId = source.id, filePath = "Trips/Bridge.jpg",
                    fileName = "Bridge.jpg", fileSize = 128, parsedTitle = "Bridge", parsedYear = null,
                    title = "Bridge", year = null))
                visible("No media in your library yet")
                device.pressDPadDown()
                device.pressDPadCenter()
                visible(source.name)
                device.pressBack()
                visible("Open Sources")
                database.sources().upsert(source.copy(ignoredFolders = emptyList()))
                visible("Browse Photos")
                device.pressDPadDown()
                device.pressDPadCenter()
                visible("Trips")
            }
        } finally {
            database.movies().deleteForSource(source.id)
            database.sources().delete(source.id)
        }
    }

    private fun captureFocus(stage: String) {
        var window = ""
        scenario?.onActivity {
            window = " windowFocused=${it.window.decorView.hasWindowFocus()} lifecycle=${it.lifecycle.currentState}" +
                " viewFocus=${it.currentFocus?.javaClass?.simpleName} touchMode=${it.window.decorView.isInTouchMode}"
        }
        val xml = ByteArrayOutputStream().also { device.dumpWindowHierarchy(it) }.toString("UTF-8")
        val relevant = Regex("<node\\b[^>]*>").findAll(xml).map { it.value }.filter { node ->
            node.contains("focused=\"true\"") || node.contains("selected=\"true\"") ||
                listOf("Home", "Library", "Photos", "Search", "Sources", "Settings").any { node.contains("text=\"$it\"") }
        }.map { node ->
            val attributes = Regex("([\\w-]+)=\"([^\"]*)\"").findAll(node)
                .associate { it.groupValues[1] to it.groupValues[2] }
            listOf("text", "content-desc", "focused", "selected", "focusable", "bounds")
                .joinToString(",") { "$it=${attributes[it].orEmpty()}" }
        }.joinToString(" | ")
        focusSnapshots += "$stage package=${device.currentPackageName}$window [$relevant]"
    }

    private fun visible(text: String) {
        val found = device.wait(Condition<UiDevice, Boolean> { hasVisibleText(text) }, 10_000)
        if (!found) captureFocus("assertion timeout")
        assertTrue("Expected TV screen text: $text\n${focusSnapshots.joinToString("\n").take(3_600)}", found)
        device.waitForIdle()
    }

    private fun hasVisibleText(text: String): Boolean {
        // Refresh cached Compose nodes after switching tabs, as the watchlist tests do.
        if (Build.VERSION.SDK_INT >= 34) {
            InstrumentationRegistry.getInstrumentation().uiAutomation.clearCache()
        }
        return device.findObjects(By.text(text)).any { node ->
            node.text == text && !node.visibleBounds.isEmpty
        }
    }
}
